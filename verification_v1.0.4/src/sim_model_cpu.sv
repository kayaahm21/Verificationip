`timescale 1ns / 1ps

// =====================================================================
// sim_model_cpu  (v1.0.4)
//
// PCIe UltraScale+ IP'sinin yerine konan sadelestirilmis simulasyon modeli (VIP) + islemci modeli.
//
// CPU -> FPGA yonu (v1.0.2'den):
//   * Senaryo dosyasini okur, TLP'leri m_axis_cq_* portundan tasarima surer
//   * Bekle / huzme basi komutlarini calistirir (99999999, 88888888, 77777777)
//
// FPGA -> CPU yonu:
//   * s_axis_rq_* portundan gelen memory write TLP'lerini yakalar, islemci hafizasina yazar
//   * Hafizadaki circular buffer'i, CPU->FPGA konfigurasyon mesajindan (1DEA0001) programlar
//   * MSI (kesme) gelince buffer'dan yeni mesajlari okuyup cikti txt dosyasina yazar
//
// Ayrica: user_clk (125 MHz), user_reset, dahili link-up ve MSI cevabi (msi_sent) uretir.
//
// Modul adi ve port adlari KUCUK HARFLIDIR: VHDL'den (buyuk/kucuk harf duyarsiz)
// cagrilirken karisiklik olmasin diye.
// =====================================================================
module sim_model_cpu #(
    parameter string INPUT_FILE       = "input_data.txt",  // senaryo dosyasi (+TLP_FILE=<dosya> ile de verilebilir)
    parameter int    CQ_KEEP_WIDTH    = 8,                 // m_axis_cq_tkeep genisligi (256-bit -> DWORD basina 8 bit)
    parameter int    RQ_KEEP_WIDTH    = 8,                 // s_axis_rq_tkeep genisligi
    parameter string BEAM_SOURCE      = "SCRIPT",          // "SCRIPT": HB'yi senaryo uretir, "DESIGN": gercek modul uretir
                                                           //   (+BEAM_SOURCE=<SCRIPT|DESIGN> ile de verilebilir)
    parameter int    BEAM_PULSE_CLKS  = 1,                 // uretilen HB darbesinin genisligi (clock)
    parameter int    BEAM_ACTIVE_HIGH = 1,                 // 1: HB aktif-yuksek

    // ---- v1.0.4: islemci modeli ----
    // v1.0.4: her buffer icin ayri dosya: <OUT_PREFIX>_sifpga.txt / _shob1.txt / _shob2.txt / _iub.txt
    parameter string OUT_PREFIX       = "cpu_out",         // ayristirilmis mesajlarin dosya on eki (+CPU_OUT=)
    parameter int    ISR_ALL_BUFFERS  = 0,                 // 1: kesme vektoru ne olursa olsun 4 buffer'i da oku
                                                           // 0: yalnizca vektorde set olan bitlerin buffer'ini oku
    parameter string TRACE_FILE       = "rq_trace.txt",    // gelen tum TLP'lerin izi (+RQ_TRACE=)
    parameter int    ISR_LATENCY_NS   = 100,               // MSI'dan sonra ISR'nin baslamasi icin bekleme (ns)
    parameter bit [31:0] CFG_MSG_ID   = 32'h1DEA0001,      // buffer'i programlayan mesajin ID'si
    parameter int    CFG_BIG_ENDIAN   = 0,                 // konfigurasyon alanlari: 0 = little-endian
    parameter int    PTR_BIG_ENDIAN   = 0,                 // pointer degeri:         0 = little-endian
    parameter int    MSG_BIG_ENDIAN   = 0                  // mesaj ID/len alanlari:  0 = little-endian
)(
    input  logic                     sys_clk,            // disaridan gelir (VIP icinde kullanilmiyor)

    output logic                     user_clk,           // 125 MHz
    output logic                     user_reset,         // aktif yuksek

    // ---- CQ: VIP -> tasarim ----
    output logic [255:0]             m_axis_cq_tdata,
    output logic [CQ_KEEP_WIDTH-1:0] m_axis_cq_tkeep,
    output logic                     m_axis_cq_tlast,
    input  logic                     m_axis_cq_tready,
    output logic [87:0]              m_axis_cq_tuser,
    output logic                     m_axis_cq_tvalid,

    // ---- RQ: tasarim -> VIP (FPGA'nin islemci hafizasina yazdigi TLP'ler) ----
    input  logic [255:0]             s_axis_rq_tdata,
    input  logic [RQ_KEEP_WIDTH-1:0] s_axis_rq_tkeep,
    input  logic                     s_axis_rq_tlast,
    output logic [3:0]               s_axis_rq_tready,   // gercek IP gibi 4 bit
    input  logic [61:0]              s_axis_rq_tuser,
    input  logic                     s_axis_rq_tvalid,

    // ---- MSI ----
    input  logic [31:0]              cfg_interrupt_msi_int,
    output logic                     cfg_interrupt_msi_sent,
    output logic                     cfg_interrupt_msi_fail,

    // ---- Huzme basi (HB) ----
    input  logic                     huzme_basi_obs,     // tasarimdaki HB teli (VIP bunu IZLER)
    output logic                     huzme_basi_gen      // VIP'in URETTIGI HB (sadece SCRIPT modunda anlamli)
);
    import cpu_pkg::*;
    import scn_pkg::*;

    localparam int KEEP_GRAN = (256/8) / CQ_KEEP_WIDTH;

    // -----------------------------------------------------------------
    // Saat / reset / link
    // -----------------------------------------------------------------
    initial begin user_clk = 1'b0; forever #4 user_clk = ~user_clk; end   // 125 MHz (8 ns periyot)

    logic user_lnk_up;   // sadece dahili: driver'i reset + link sonrasi baslatir

    initial begin
        user_reset  = 1'b1;
        user_lnk_up = 1'b0;
        repeat (20) @(posedge user_clk);
        user_reset  = 1'b0;
        repeat (20) @(posedge user_clk);
        user_lnk_up = 1'b1;
    end

    // -----------------------------------------------------------------
    // RQ: ready ver; kabul edilen beat'leri TLP'ye birlestirip islemci modeline ver
    // -----------------------------------------------------------------
    assign s_axis_rq_tready = 4'hF;

    cpu_model    cpu;       // islemci (hafiza + buffer + ISR)
    rq_assembler asm;       // RQ beat birlestirici
    rq_pkt       rx_pkt;
    bit          rx_done;

    always @(posedge user_clk) begin
        if (asm != null && cpu != null && !user_reset && s_axis_rq_tvalid && s_axis_rq_tready[0]) begin
            // Not: yan etkili cagri if() icinde degil, ayri ifadede yapilir (simulator farklarindan korunmak icin)
            rx_done = asm.push_beat(s_axis_rq_tdata, s_axis_rq_tkeep[7:0], s_axis_rq_tlast,
                                    s_axis_rq_tuser, rx_pkt);
            if (rx_done) cpu.on_pkt(rx_pkt);
        end
    end

    // -----------------------------------------------------------------
    // MSI cevabi: |msi_int'in her yukselen kenari icin 3 clock sonra TEK clock'luk msi_sent darbesi.
    // (Tasarim msi_int'i sent gelene kadar tutsa da, tek clock'luk darbe verse de calisir.)
    // -----------------------------------------------------------------
    assign cfg_interrupt_msi_fail = 1'b0;
    // v1.0.4: vektorun her biti ayri izlenir; herhangi bir bitin yukselen kenari yeni istektir.
    logic [31:0] msi_int_d = '0;
    logic [31:0] msi_pend  = '0;    // istek aninda yakalanan bitler (sent'e kadar birikir)
    logic [31:0] irq_vec   = '0;    // msi_sent ile islemciye ulasan bitler (ISR okuyup temizler)
    logic        msi_req   = 1'b0;
    logic [1:0]  msi_dly   = 2'b00;
    initial cfg_interrupt_msi_sent = 1'b0;
    always @(posedge user_clk) begin     // always_ff degil: ayni degiskene initial de yaziyor
        msi_int_d              <= cfg_interrupt_msi_int;
        msi_req                <= |(cfg_interrupt_msi_int & ~msi_int_d);
        msi_dly                <= {msi_dly[0], msi_req};
        cfg_interrupt_msi_sent <= msi_dly[1];
        if (|(cfg_interrupt_msi_int & ~msi_int_d))
            msi_pend = msi_pend | (cfg_interrupt_msi_int & ~msi_int_d);
        if (msi_dly[1]) begin           // sent darbesinin uretildigi clock
            irq_vec  = irq_vec | msi_pend;
            msi_pend = '0;
        end
    end

    // -----------------------------------------------------------------
    // Kesme -> ISR
    //  msi_sent darbesi "kesme islemciye ulasti" demektir. ISR:
    //    1) o ana kadar gelen tum RQ TLP'lerinin islenmesini bekler (MSI, yazmalarin ardindan gelir)
    //    2) ISR_LATENCY_NS bekler
    //    3) cpu.run_isr()
    //  ISR yalnizca pointer'in gosterdigi yere kadar olani okur; kacan kesme veriyi kaybettirmez,
    //  veri bir sonraki ISR'de okunur.
    // -----------------------------------------------------------------
    bit          irq_flag = 1'b0;
    logic [31:0] isr_vec;
    always @(posedge user_clk)
        if (cfg_interrupt_msi_sent) irq_flag = 1'b1;

    initial begin
        forever begin
            wait (irq_flag && cpu != null && asm != null);
            irq_flag = 1'b0;
            wait (!asm.collecting);
            #(ISR_LATENCY_NS);
            wait (!asm.collecting);
            isr_vec = irq_vec;          // ISR sirasinda gelen yeni bitler bir sonraki ISR'ye kalir
            irq_vec = '0;
            if (ISR_ALL_BUFFERS != 0) isr_vec = isr_vec | 32'h0000_000F;
            cpu.run_isr(isr_vec);
        end
    end

    // -----------------------------------------------------------------
    // Huzme basi arayuzu
    // -----------------------------------------------------------------
    beam_if bif (.clk(user_clk));
    initial bif.gen = (BEAM_ACTIVE_HIGH != 0) ? 1'b0 : 1'b1;   // bosta seviyesi
    assign bif.obs        = huzme_basi_obs;    // tasarimdan gelen HB'yi arayuze ver
    assign huzme_basi_gen = bif.gen;           // VIP'in urettigi HB'yi disari ver

    // -----------------------------------------------------------------
    // CQ arayuzu (AXI-S) ve port baglantilari
    // -----------------------------------------------------------------
    axis_tx_if #(.DATA_WIDTH(256), .TUSER_WIDTH(88), .KEEP_GRAN(KEEP_GRAN))
        cq_if (.aclk(user_clk), .rst_n(~user_reset & user_lnk_up));

    assign m_axis_cq_tdata  = cq_if.tdata;
    assign m_axis_cq_tkeep  = cq_if.tkeep;
    assign m_axis_cq_tlast  = cq_if.tlast;
    assign m_axis_cq_tuser  = cq_if.tuser;
    assign m_axis_cq_tvalid = cq_if.tvalid;
    assign cq_if.tready     = m_axis_cq_tready;

    // -----------------------------------------------------------------
    // Senaryo motoru: generator -> mailbox -> driver (+ beam_ctrl, + cpu_model)
    // -----------------------------------------------------------------
    mailbox #(scn_cmd)     mbx;
    driver  #(256, 88, KEEP_GRAN) drv;
    generator              gen;
    beam_ctrl              beam;
    string                 file_name;
    string                 beam_source;
    string                 out_name;   // dosya on eki
    string                 trace_name;

    initial begin
        $timeformat(-9, 0, " ns", 0);    // %t ciktilarini ns olarak yaz

        // Komut satiri argumani parametreye gore onceliklidir.
        if (!$value$plusargs("TLP_FILE=%s", file_name))      file_name   = INPUT_FILE;
        if (!$value$plusargs("BEAM_SOURCE=%s", beam_source)) beam_source = BEAM_SOURCE;
        if (!$value$plusargs("CPU_OUT=%s", out_name))        out_name    = OUT_PREFIX;
        if (!$value$plusargs("RQ_TRACE=%s", trace_name))     trace_name  = TRACE_FILE;
        if (beam_source != "SCRIPT" && beam_source != "DESIGN") begin
            $error("[VIP] BEAM_SOURCE='%s' gecersiz, SCRIPT kullaniliyor.", beam_source);
            beam_source = "SCRIPT";
        end
        if (RQ_KEEP_WIDTH != 8)
            $warning("[VIP] RQ_KEEP_WIDTH=%0d, 256-bit RQ icin 8 olmali.", RQ_KEEP_WIDTH);
        $display("[VIP] senaryo=%s | HB kaynagi=%s | cikti on eki=%s | iz=%s",
                 file_name, beam_source, out_name, trace_name);

        // Islemci modeli once kurulur (driver buffer'i programlamak icin ona ihtiyac duyar)
        cpu  = new(out_name, trace_name, bit'(CFG_BIG_ENDIAN != 0), bit'(PTR_BIG_ENDIAN != 0),
                   bit'(MSG_BIG_ENDIAN != 0), CFG_MSG_ID);
        asm  = new();

        mbx  = new();
        beam = new(bif, beam_source, BEAM_PULSE_CLKS, bit'(BEAM_ACTIVE_HIGH != 0));
        drv  = new(cq_if, mbx, beam, cpu);
        gen  = new(mbx, file_name);

        drv.reset();                 // reset + link up bekler
        fork drv.run(); join_none    // komutlari arka planda calistir
        gen.run();                   // dosyayi oku, mailbox'a koy
    end
endmodule
