`timescale 1ns / 1ps

// =====================================================================
// aurora_8b10b_vip  (v1.0.5)  -  Aurora 8b/10b IP'sinin (IUB tarafi) yerine konan GOZLEMCI VIP
//
// Hedef: Aurora_aurora_8b10b_0_2 (1 lane, 32 bit AXI-S, Framing, Duplex, UFC YOK) modulunun portlariyla
// ayni portlara sahip olmak. DRP portlari (gt0_drp*) bilerek YOKTUR (IP'de de yoktu; hata kaynagiydi).
//
// Gozlemci davranisi (aurora_64b66b_vip ile ayni mantik; v1.0.5: gelen mesaj ID+LEN+veri olarak birlestirilip loglanir):
//   * Link modeli: 125 MHz saat (tx_out_clk), reset/powergood/lock sirasi, channel_up/lane_up
//   * s_axi_tx_* her zaman kabul edilir (tready=1) ve log dosyasina yazilir
//   * RX tarafi bostur (cevap uretilmez)
//
// Log dosyasi: aurora8b10b_obs_<UNIT_NAME>.txt
//
// Davranis varsayilan olarak ACIKTIR. Yalnizca sade govde istenirse VIP_STUB tanimlanir.
//
// Vektor genislikleri ([0:0]) BD sarmalayicisindaki std_logic_vector(0 to 0) tipleriyle uyumludur.
// Aurora'ya ozgu arayuzler (CORE_CONTROL/CORE_STATUS/GT_SERIAL) paketlenmemistir (duz pin);
// BD'de tools/bd_externals_aurora.tcl icindeki make_iub_externals ile dis portlar acilir.
// =====================================================================
`ifndef VIP_STUB
  `ifndef VIP_BEHAVIORAL
    `define VIP_BEHAVIORAL
  `endif
`endif

module aurora_8b10b_vip #(
    parameter UNIT_NAME      = "iub",   // log dosyasi: aurora8b10b_obs_<UNIT_NAME>.txt
    parameter LOG_ENABLE     = 1,       // 0: log yazma
    parameter LINK_UP_CLKS   = 625,     // reset'ten sonra channel_up'a kadar user_clk sayisi (~5 us)
    // ---- v1.0.5: mesaj tamponu / log ----
    parameter MAX_MSG_BYTES  = 65536,   // en buyuk mesaj (ID+LEN+veri) bayt sayisi
    parameter LOG_RAW_BEATS  = 1,       // 1: her beat icin USER_TX satiri yaz (buyuk mesajlarda 0 yapilabilir)
    parameter LOG_DATA_BYTES = 64,      // MSG satirina yazilan en fazla veri bayti (fazlasi " ..." ile kisaltilir)
    // ---- v1.0.5: HUZPAR cevabi (istek ID 00000001 -> cevap ID 00000002) ----
    parameter RESP_ENABLE    = 1,       // 0: cevap uretme (yalnizca gozlemci)
    parameter RESP_DELAY_CLKS = 125,    // isteğin son beat'inden cevaba bekleme (125 clk = 1 us)
    parameter M_ADK          = 4,       // ADK sayisi (radar icin 10)
    parameter N_CORE         = 4,       // ADK basina cekirdek sayisi (radar icin 24)
    parameter F_EXTRA        = 0        // IUB kontrol parametrelerine eklenen bayt (F)
)(
    // ---- AXI TX (USER_DATA_S_AXIS_TX) ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 USER_DATA_S_AXIS_TX TDATA" *)  input  wire [31:0] s_axi_tx_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 USER_DATA_S_AXIS_TX TKEEP" *)  input  wire [3:0]  s_axi_tx_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 USER_DATA_S_AXIS_TX TVALID" *) input  wire        s_axi_tx_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 USER_DATA_S_AXIS_TX TLAST" *)  input  wire        s_axi_tx_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 USER_DATA_S_AXIS_TX TREADY" *) output wire        s_axi_tx_tready,

    // ---- AXI RX (USER_DATA_M_AXIS_RX), tready yok ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 USER_DATA_M_AXIS_RX TDATA" *)  output wire [31:0] m_axi_rx_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 USER_DATA_M_AXIS_RX TKEEP" *)  output wire [3:0]  m_axi_rx_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 USER_DATA_M_AXIS_RX TVALID" *) output wire        m_axi_rx_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 USER_DATA_M_AXIS_RX TLAST" *)  output wire        m_axi_rx_tlast,

    // ---- GT seri I/O (1 lane; [0:0] BD sarmalayicisindaki (0 to 0) tipi icin) ----
    input  wire [0:0]   rxp,
    input  wire [0:0]   rxn,
    output wire [0:0]   txp,
    output wire [0:0]   txn,

    // ---- GT referans saati ----
    input  wire         gt_refclk1,

    // ---- Hata / durum ----
    output wire         frame_err,
    output wire         hard_err,
    output wire         soft_err,
    output wire [0:0]   lane_up,
    output wire         channel_up,
    output wire         crc_pass_fail_n,
    output wire         crc_valid,

    // ---- Sistem arayuzu ----
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 user_clk CLK",
       X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF USER_DATA_S_AXIS_TX:USER_DATA_M_AXIS_RX, FREQ_HZ 125000000" *)
    input  wire         user_clk,
    input  wire         sync_clk,
    input  wire         gt_reset,
    input  wire         reset,
    output wire         sys_reset_out,
    input  wire         power_down,
    input  wire [2:0]   loopback,
    output wire         tx_lock,
    input  wire         init_clk_in,
    output wire         tx_resetdone_out,
    output wire         rx_resetdone_out,
    output wire         link_reset_out,
    output wire [0:0]   gt_powergood,
    output wire         tx_out_clk,
    output wire         bufg_gt_clr_out,
    input  wire         pll_not_locked
);

`ifdef VIP_BEHAVIORAL
    // =================================================================
    // DAVRANIS (yalnizca simulasyon)
    // =================================================================

    // ---- Dahili 125 MHz saat: link modeli ve tx_out_clk icin. Kullanici verisi log'u user_clk girisiyle orneklenir. ----
    reg clk = 1'b0;
    always #4 clk = ~clk;                     // 8 ns periyot
    assign tx_out_clk      = clk;             // BD'deki BUFG_GT zinciri bunu kullanir
    assign bufg_gt_clr_out = 1'b0;

    // ---- Link modeli ----
    // Sayac her zaman ilerler. reset / gt_reset / power_down'un YUKSELEN KENARI sirayi bastan baslatir.
    // (Seviyeye bagli degil: BD, reset'i sys_reset_out'tan turetiyorsa kilitlenme olmasin diye.)
    integer cnt = 0;
    reg     rst_d = 1'b0;
    wire    rst_now = (reset === 1'b1) || (gt_reset === 1'b1) || (power_down === 1'b1);
    always @(posedge clk) begin
        rst_d <= rst_now;
        if (rst_now && !rst_d)      cnt <= 0;
        else if (cnt < 1000000)     cnt <= cnt + 1;
    end

    assign gt_powergood     = (cnt >= 5)  ? 1'b1 : 1'b0;
    assign sys_reset_out    = (cnt < 20);                    // aktif yuksek
    assign tx_lock          = (cnt >= 8);
    assign tx_resetdone_out = (cnt >= 10);
    assign rx_resetdone_out = (cnt >= 10);
    assign channel_up       = (cnt >= LINK_UP_CLKS);
    assign lane_up          = channel_up ? 1'b1 : 1'b0;
    assign link_reset_out   = ~channel_up;
    assign frame_err        = 1'b0;
    assign hard_err         = 1'b0;
    assign soft_err         = 1'b0;
    assign crc_pass_fail_n  = 1'b1;
    assign crc_valid        = 1'b0;
    assign txp              = 1'b0;
    assign txn              = 1'b1;

    // ---- RX: yalnizca HUZPAR cevabi icin kullanilir ----
    // RX cikislari HUZPAR cevap motoru tarafindan surulur (asagida); tready yoktur, beat'ler dogrudan basilir
    reg [31:0] rx_tdata_r  = 32'd0;
    reg [3:0]  rx_tkeep_r  = 4'd0;
    reg        rx_tvalid_r = 1'b0;
    reg        rx_tlast_r  = 1'b0;
    assign m_axi_rx_tdata  = rx_tdata_r;
    assign m_axi_rx_tkeep  = rx_tkeep_r;
    assign m_axi_rx_tvalid = rx_tvalid_r;
    assign m_axi_rx_tlast  = rx_tlast_r;

    // ---- Kullanici verisi: her zaman kabul ----
    assign s_axi_tx_tready = 1'b1;

    // ---- Log ----
    integer fd = 0;
    reg [8*64-1:0] fname;
    initial begin
        if (LOG_ENABLE != 0) begin
            $sformat(fname, "aurora8b10b_obs_%0s.txt", UNIT_NAME);
            fd = $fopen(fname, "w");
            $display("[AURORA8B10B %0s] DAVRANIS SURUMU aktif (v1.0.5). Log dosyasi: %0s", UNIT_NAME, fname);
            if (fd == 0) $display("[AURORA8B10B %0s] HATA: log dosyasi acilamadi", UNIT_NAME);
            else begin
                $fdisplay(fd, "# aurora_8b10b_vip gozlemci logu (birim=%0s). Zamanlar ns.", UNIT_NAME);
                $fflush(fd);
            end
        end
    end

    // Link durumu degisimleri (dahili saat)
    reg cu_d = 1'b0;
    always @(posedge clk) begin
        cu_d <= channel_up;
        if (fd != 0 && channel_up !== cu_d) begin
            $fdisplay(fd, "%0d LINK channel_up=%0d lane_up=%b", $time, channel_up, lane_up);
            $fflush(fd);
        end
    end

    // =================================================================
    // Kullanici verisi: tasarimin s_axi_tx_* sinyalleri user_clk ile (BD'de SHOB IP'sinden gelen saat)
    // surulur; yaris kosullarindan kacinmak icin user_clk girisiyle orneklenir. Cevap da user_clk
    // domaininde surulur.
    //
    // Mesaj bicimi: ID (4 bayt) + LEN (4 bayt, yalnizca VERI bayt sayisi) + veri.
    // 32 bitlik beat'ler tlast'a kadar toplanir (tkeep'te 1 olan baytlar sirayla, ilk bayt tdata[7:0]).
    // ID ve LEN, ilk iki 32 bitlik kelimenin sayisal degeridir (SHOB UFC kelimeleriyle ayni).
    // Mesaj bitince obs dosyasina "MSG id=... len=... data=BYTE0 BYTE1 ..." satiri yazilir.
    //
    // v1.0.5: HUZPAR istegi (ID 00000001) gelince RESP_DELAY_CLKS sonra HUZPAR cevabi (ID 00000002) verilir.
    //   Istek verisi: huzme ID (4) + IUB kontrol (28+F) + reserved (8) + M x (172*N + 20) bayt ADK huzpar
    //     => beklenen LEN = M*(172*N+20) + 40 + F  (M=N=4 icin 2872)
    //   Cevap verisi: huzme ID (4) + huzme basi zamani gclk (4) + M x huzme ID (4) => LEN = 4*M + 8
    //     (M=4 icin 24; toplam 8 + 24 = 32 bayt = 8 beat)
    //   gclk: bu VIP'te isteğin son beat'inde okunan serbest kosan user_clk sayaci (uint32).
    //   Cevap beat'leri tready beklenmeden art arda basilir; tkeep=0xF, son beat'te tlast=1.
    //   Diger mesaj ID'leri cevapsiz kalir (yalnizca loglanir).
    // =================================================================
    localparam [31:0] ID_HUZPAR_REQ  = 32'h00000001;
    localparam [31:0] ID_HUZPAR_RESP = 32'h00000002;
    localparam integer EXP_REQ_LEN   = M_ADK * (172 * N_CORE + 20) + 40 + F_EXTRA;
    localparam integer RESP_LEN      = 4 * M_ADK + 8;
    localparam integer RESP_WORDS    = 2 + RESP_LEN / 4;       // ID + LEN + veri kelimeleri

    reg [7:0] mb [0:MAX_MSG_BYTES-1];   // toplanan mesaj baytlari
    integer   mcount = 0;               // toplanan bayt sayisi
    integer   mi;
    reg [31:0] m_id, m_len;
    reg [31:0] gclk = 32'd0;            // serbest kosan sayac (user_clk)

    // cevap motoru
    reg [31:0] rw [0:RESP_WORDS-1];
    integer rsp_state = 0;              // 0: bos, 1: gecikme, 2: gonderim
    integer dly_cnt   = 0;
    integer widx      = 0;
    reg [31:0] hz_id;
    integer ri;

    task iub_msg_done;
        begin
            if (mcount < 8) begin
                if (fd != 0) begin
                    $fdisplay(fd, "%0d MSG_KISA bayt=%0d (en az 8 bayt: ID+LEN gerekir), yok sayildi", $time, mcount);
                    $fflush(fd);
                end
            end else begin
                m_id  = {mb[3], mb[2], mb[1], mb[0]};
                m_len = {mb[7], mb[6], mb[5], mb[4]};
                if (fd != 0) begin
                    $fwrite(fd, "%0d MSG id=%h len=%0d data=", $time, m_id, m_len);
                    for (mi = 8; mi < mcount && mi < MAX_MSG_BYTES && (mi - 8) < LOG_DATA_BYTES; mi = mi + 1) begin
                        if (mi > 8) $fwrite(fd, " ");
                        $fwrite(fd, "%h", mb[mi]);
                    end
                    if ((mcount - 8) > LOG_DATA_BYTES) $fwrite(fd, " ... (toplam %0d veri bayti)", mcount - 8);
                    $fwrite(fd, "\n");
                    if (m_len != mcount - 8)
                        $fdisplay(fd, "%0d MSG_UYARI len=%0d ama %0d veri bayti geldi", $time, m_len, mcount - 8);
                    $fflush(fd);
                end
                if (mcount > MAX_MSG_BYTES && fd != 0)
                    $fdisplay(fd, "%0d MSG_UYARI mesaj %0d bayt, tampon %0d bayt: fazlasi saklanmadi", $time, mcount, MAX_MSG_BYTES);

                // --- HUZPAR istegi ---
                if (RESP_ENABLE != 0 && m_id == ID_HUZPAR_REQ) begin
                    if (m_len != EXP_REQ_LEN && fd != 0) begin
                        $fdisplay(fd, "%0d MSG_UYARI HUZPAR len=%0d, beklenen %0d (M=%0d N=%0d F=%0d)",
                                  $time, m_len, EXP_REQ_LEN, M_ADK, N_CORE, F_EXTRA);
                        $fflush(fd);
                    end
                    if (mcount < 12) begin
                        if (fd != 0) begin
                            $fdisplay(fd, "%0d HUZPAR_CEVAP yok: veri 4 bayttan kisa (huzme ID yok)", $time);
                            $fflush(fd);
                        end
                    end else if (rsp_state != 0) begin
                        if (fd != 0) begin
                            $fdisplay(fd, "%0d HUZPAR_CEVAP MESGUL: onceki cevap bitmeden yeni istek geldi, yok sayildi", $time);
                            $fflush(fd);
                        end
                    end else begin
                        hz_id = {mb[11], mb[10], mb[9], mb[8]};          // huzme ID (veri baytlari 0..3)
                        rw[0] = ID_HUZPAR_RESP;
                        rw[1] = RESP_LEN;
                        rw[2] = hz_id;                                    // huzme ID
                        rw[3] = gclk;                                     // huzme basi zamani (gclk)
                        for (ri = 0; ri < M_ADK; ri = ri + 1) rw[4 + ri] = hz_id;   // ADK cevaplari (huzme ID)
                        rsp_state <= 1;
                        dly_cnt   <= RESP_DELAY_CLKS;
                        if (fd != 0) begin
                            $fdisplay(fd, "%0d HUZPAR_CEVAP planlandi id=%h len=%0d huzme_id=%h gclk=%0d (%0d clk sonra)",
                                      $time, ID_HUZPAR_RESP, RESP_LEN, hz_id, gclk, RESP_DELAY_CLKS);
                            $fflush(fd);
                        end
                    end
                end
            end
            mcount = 0;
        end
    endtask

    always @(posedge user_clk) begin
        gclk <= gclk + 1;

        // --- 1) TX: gelen beat'leri mesaja ekle ---
        if (s_axi_tx_tvalid && s_axi_tx_tready) begin
            if (LOG_RAW_BEATS != 0 && fd != 0) begin
                $fdisplay(fd, "%0d USER_TX data=%h keep=%h last=%0d", $time,
                          s_axi_tx_tdata, s_axi_tx_tkeep, s_axi_tx_tlast);
                $fflush(fd);
            end
            for (mi = 0; mi < 4; mi = mi + 1)
                if (s_axi_tx_tkeep[mi]) begin
                    if (mcount < MAX_MSG_BYTES) mb[mcount] = s_axi_tx_tdata[8*mi +: 8];
                    mcount = mcount + 1;
                end
            if (s_axi_tx_tlast) iub_msg_done;
        end

        // --- 2) RX: varsayilan bos; cevap beat'lerini art arda ver ---
        rx_tvalid_r <= 1'b0;
        rx_tlast_r  <= 1'b0;
        rx_tkeep_r  <= 4'd0;
        rx_tdata_r  <= 32'd0;
        case (rsp_state)
            1: begin
                if (dly_cnt <= 1) begin rsp_state <= 2; widx <= 0; end
                else                   dly_cnt <= dly_cnt - 1;
            end
            2: begin
                rx_tdata_r  <= rw[widx];
                rx_tkeep_r  <= 4'hF;
                rx_tvalid_r <= 1'b1;
                rx_tlast_r  <= (widx == RESP_WORDS - 1);
                if (fd != 0) begin
                    $fdisplay(fd, "%0d RX idx=%0d word=%h%s", $time, widx, rw[widx], (widx == RESP_WORDS - 1) ? " last" : "");
                    $fflush(fd);
                end
                widx <= widx + 1;
                if (widx == RESP_WORDS - 1) begin
                    rsp_state <= 0;
                    if (fd != 0) begin
                        $fdisplay(fd, "%0d HUZPAR_CEVAP bitti id=%h", $time, ID_HUZPAR_RESP);
                        $fflush(fd);
                    end
                end
            end
            default: ;
        endcase
    end

`else
    // =================================================================
    // SADE GOVDE (VIP_STUB): tum cikislar sabit
    // =================================================================
    initial $display("[AURORA8B10B] UYARI: SADE GOVDE (VIP_STUB) aktif - saat/link/log YOK.");
    assign s_axi_tx_tready = 1'b1;
    assign m_axi_rx_tdata = 32'd0; assign m_axi_rx_tkeep = 4'd0;
    assign m_axi_rx_tvalid = 1'b0; assign m_axi_rx_tlast = 1'b0;
    assign txp = 1'b0; assign txn = 1'b1;
    assign frame_err = 1'b0; assign hard_err = 1'b0; assign soft_err = 1'b0;
    assign lane_up = 1'b0; assign channel_up = 1'b0;
    assign crc_pass_fail_n = 1'b1; assign crc_valid = 1'b0;
    assign sys_reset_out = 1'b1; assign tx_lock = 1'b0;
    assign tx_resetdone_out = 1'b0; assign rx_resetdone_out = 1'b0;
    assign link_reset_out = 1'b1; assign gt_powergood = 1'b0;
    assign tx_out_clk = gt_refclk1; assign bufg_gt_clr_out = 1'b0;
`endif

endmodule
