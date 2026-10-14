`timescale 1ns / 1ps

// =====================================================================
// sim_model_cpu  (v1.0.2)
//
// PCIe UltraScale+ IP'sinin yerine konan sadelestirilmis simulasyon modeli (VIP).
// Gorevleri:
//   1. user_clk (125 MHz), user_reset (aktif yuksek) ve dahili link-up uretmek
//   2. Senaryo dosyasini okuyup TLP'leri CQ portundan (m_axis_cq_*) tasarima surmek
//   3. RQ portunda (s_axis_rq_*) sadece "ready" vermek
//   4. MSI isteklerine (cfg_interrupt_msi_*) cevap vermek
//   5. Huzme basi (HB) sinyalini izlemek (huzme_basi_obs) ve gerektiginde uretmek (huzme_basi_gen)
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
    parameter int    BEAM_ACTIVE_HIGH = 1                  // 1: HB aktif-yuksek
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

    // ---- RQ: tasarim -> VIP (simdilik sadece ready veriliyor) ----
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
    // RQ: sadece ready ver (4 bitin hepsi 1)
    // -----------------------------------------------------------------
    assign s_axis_rq_tready = 4'hF;

    // -----------------------------------------------------------------
    // MSI cevabi: msi_int sifirdan farkliysa 2 clock sonra msi_sent darbesi
    // -----------------------------------------------------------------
    assign cfg_interrupt_msi_fail = 1'b0;
    logic [1:0] msi_dly;
    always_ff @(posedge user_clk) begin
        msi_dly                <= {msi_dly[0], |cfg_interrupt_msi_int};
        cfg_interrupt_msi_sent <= msi_dly[1] & |cfg_interrupt_msi_int;
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
    // Senaryo motoru: generator -> mailbox -> driver (+ beam_ctrl)
    // -----------------------------------------------------------------
    mailbox #(scn_cmd)     mbx;
    driver  #(256, 88, KEEP_GRAN) drv;
    generator              gen;
    beam_ctrl              beam;
    string                 file_name;
    string                 beam_source;

    initial begin
        $timeformat(-9, 0, " ns", 0);    // %t ciktilarini ns olarak yaz

        // Senaryo dosyasi ve HB kaynagi: komut satiri argumani parametreye gore onceliklidir.
        if (!$value$plusargs("TLP_FILE=%s", file_name))      file_name   = INPUT_FILE;
        if (!$value$plusargs("BEAM_SOURCE=%s", beam_source)) beam_source = BEAM_SOURCE;
        if (beam_source != "SCRIPT" && beam_source != "DESIGN") begin
            $error("[VIP] BEAM_SOURCE='%s' gecersiz, SCRIPT kullaniliyor.", beam_source);
            beam_source = "SCRIPT";
        end
        $display("[VIP] senaryo=%s | HB kaynagi=%s", file_name, beam_source);

        mbx  = new();
        beam = new(bif, beam_source, BEAM_PULSE_CLKS, bit'(BEAM_ACTIVE_HIGH != 0));
        drv  = new(cq_if, mbx, beam);
        gen  = new(mbx, file_name);

        drv.reset();                 // reset + link up bekler
        fork drv.run(); join_none    // komutlari arka planda calistir
        gen.run();                   // dosyayi oku, mailbox'a koy
    end
endmodule
