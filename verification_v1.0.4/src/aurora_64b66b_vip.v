`timescale 1ns / 1ps

// =====================================================================
// aurora_64b66b_vip  (v1.0.4)  -  Aurora 64B/66B IP'sinin yerine konan GOZLEMCI (observer) VIP
//
// Hedef: sinyal isleme FPGA'sindaki Aurora_aurora_64b66b_0_0 IP'sinin (3 lane, 192-bit AXI-S,
// UFC acik, DUPLEX) portlariyla BIREBIR ayni portlara sahip olmak; Block Design'da (verif projesi)
// shob_1_aurora_gth / shob_2_aurora_gth hucrelerinin yerine "module reference" olarak konur.
//
// Bu surumde VIP YALNIZCA GOZLEMLER:
//   * Link modelini uretir: user_clk_out (125 MHz), resetler, gt_powergood, gt_pll_lock, channel_up, lane_up
//   * Tasarimin gonderdigi UFC mesajini (ufc_tx_req/ufc_tx_ms + s_axi_ufc_tx_*) kabul eder
//     ve HAM haliyle log dosyasina yazar. CEVAP URETMEZ (RX arayuzleri bostadir).
//   * Kullanici verisi (s_axi_tx_*) her zaman kabul edilir ve (alt 128 bit) log'a yazilir.
//
// Log dosyasi: aurora_obs_<UNIT_NAME>.txt   (zaman damgali, satir satir)
//
// Derleme: davranis varsayilan olarak acik. VIP_STUB tanimlanirsa yalnizca portlar + sabit atamalar
// (BD'nin modulu ayristirabilmesi icin sade govde) derlenir. (Verif projesi sentezlenmez; yine de dosya sentez ayristiricisina uygundur.)
//
// Arayuz gruplari (X_INTERFACE_INFO): USER_DATA_S_AXIS_TX, USER_DATA_M_AXIS_RX, UFC_S_AXIS_TX,
// UFC_M_AXIS_RX standart AXI-Stream olarak gruplanir. Aurora'ya ozgu arayuz VLNV'leri (core_control,
// core_status, gt_serial vb.) bilinmedigi icin bu portlar DUZ port olarak birakilmistir;
// BD'de baglantilar tek tek (ya da otomatik) yapilabilir.
// =====================================================================
// Davranis varsayilan olarak ACIKTIR (ekstra tanim gerekmez). Yalnizca ayristirma icin sade govde
// istenirse VIP_STUB tanimlanir. (Eski VIP_BEHAVIORAL tanimi da kabul edilir, etkisi yoktur.)
`ifndef VIP_STUB
  `ifndef VIP_BEHAVIORAL
    `define VIP_BEHAVIORAL
  `endif
`endif

module aurora_64b66b_vip #(
    parameter UNIT_NAME      = "shob_1",   // log dosyasi adi: aurora_obs_<UNIT_NAME>.txt
    parameter LOG_ENABLE     = 1,          // 0: log yazma
    parameter LINK_UP_CLKS   = 625         // reset'ten sonra channel_up'a kadar gecen user_clk sayisi (~5 us)
)(
    // ---- TX AXI4-S (USER_DATA_S_AXIS_TX) ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 USER_DATA_S_AXIS_TX TDATA" *)  input  wire [191:0] s_axi_tx_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 USER_DATA_S_AXIS_TX TLAST" *)  input  wire         s_axi_tx_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 USER_DATA_S_AXIS_TX TKEEP" *)  input  wire [23:0]  s_axi_tx_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 USER_DATA_S_AXIS_TX TVALID" *) input  wire         s_axi_tx_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 USER_DATA_S_AXIS_TX TREADY" *) output wire         s_axi_tx_tready,

    // ---- RX AXI4-S (USER_DATA_M_AXIS_RX), tready yok ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 USER_DATA_M_AXIS_RX TDATA" *)  output wire [191:0] m_axi_rx_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 USER_DATA_M_AXIS_RX TLAST" *)  output wire         m_axi_rx_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 USER_DATA_M_AXIS_RX TKEEP" *)  output wire [23:0]  m_axi_rx_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 USER_DATA_M_AXIS_RX TVALID" *) output wire         m_axi_rx_tvalid,

    // ---- UFC TX (UFC_S_AXIS_TX): tkeep/tlast yok ----
    input  wire         ufc_tx_req,
    input  wire [7:0]   ufc_tx_ms,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 UFC_S_AXIS_TX TDATA" *)  input  wire [191:0] s_axi_ufc_tx_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 UFC_S_AXIS_TX TVALID" *) input  wire         s_axi_ufc_tx_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 UFC_S_AXIS_TX TREADY" *) output wire         s_axi_ufc_tx_tready,

    // ---- UFC RX (UFC_M_AXIS_RX), tready yok ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 UFC_M_AXIS_RX TDATA" *)  output wire [191:0] m_axi_ufc_rx_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 UFC_M_AXIS_RX TKEEP" *)  output wire [23:0]  m_axi_ufc_rx_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 UFC_M_AXIS_RX TLAST" *)  output wire         m_axi_ufc_rx_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 UFC_M_AXIS_RX TVALID" *) output wire         m_axi_ufc_rx_tvalid,
    output wire         ufc_in_progress,

    // ---- GT seri I/O ----
    input  wire [0:2]   rxp,
    input  wire [0:2]   rxn,
    output wire [0:2]   txp,
    output wire [0:2]   txn,

    // ---- GT referans saati ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:diff_clock:1.0 GT_DIFF_REFCLK1 CLK_P",
       X_INTERFACE_PARAMETER = "FREQ_HZ 250000000" *)
    input  wire         gt_refclk1_p,
    (* X_INTERFACE_INFO = "xilinx.com:interface:diff_clock:1.0 GT_DIFF_REFCLK1 CLK_N" *)
    input  wire         gt_refclk1_n,
    output wire         gt_refclk1_out,

    // ---- Hata / durum ----
    output wire         hard_err,
    output wire         soft_err,
    output wire         channel_up,
    output wire [0:2]   lane_up,
    output wire         crc_pass_fail_n,
    output wire         crc_valid,

    // ---- Sistem arayuzu ----
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 user_clk_out CLK",
       X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF USER_DATA_S_AXIS_TX:USER_DATA_M_AXIS_RX:UFC_S_AXIS_TX:UFC_M_AXIS_RX, FREQ_HZ 125000000" *)
    output wire         user_clk_out,
    output wire         mmcm_not_locked_out,
    output wire         sync_clk_out,
    input  wire         reset_pb,
    input  wire         gt_rxcdrovrden_in,
    input  wire         power_down,
    input  wire [2:0]   loopback,
    input  wire         pma_init,
    output wire         gt_pll_lock,

    input  wire         init_clk,
    output wire         link_reset_out,
    output wire [2:0]   gt_powergood,
    output wire         sys_reset_out,
    output wire         gt_reset_out,
    output wire         tx_out_clk
);

`ifdef VIP_BEHAVIORAL
    // =================================================================
    // DAVRANIS (yalnizca simulasyon)
    // =================================================================

    // ---- 125 MHz kullanici saati ----
    reg clk = 1'b0;
    always #4 clk = ~clk;                     // 8 ns periyot
    assign user_clk_out = clk;
    assign sync_clk_out = clk;
    assign tx_out_clk   = clk;
    assign gt_refclk1_out = gt_refclk1_p;     // referans saati dogrudan gecer

    // ---- Link modeli ----
    // ok=1 iken sayac ilerler; reset_pb / pma_init / power_down sayaci sifirlar (link yeniden kurulur).
    // Sira: gt_powergood -> gt_pll_lock -> gt_reset_out biter -> sys_reset_out biter -> channel_up/lane_up
    integer cnt = 0;
    wire    ok  = !(reset_pb === 1'b1 || pma_init === 1'b1 || power_down === 1'b1);
    always @(posedge clk) begin
        if (!ok) cnt <= 0;
        else if (cnt < 1000000) cnt <= cnt + 1;
    end

    assign gt_powergood        = (cnt >= 5)  ? 3'b111 : 3'b000;
    assign gt_pll_lock         = (cnt >= 8);
    assign gt_reset_out        = (cnt < 10);                     // aktif yuksek
    assign sys_reset_out       = (cnt < 20);                     // aktif yuksek
    assign mmcm_not_locked_out = (cnt < 4);
    assign channel_up          = (cnt >= LINK_UP_CLKS);
    assign lane_up             = (cnt >= LINK_UP_CLKS) ? 3'b111 : 3'b000;
    assign link_reset_out      = ~channel_up;
    assign hard_err            = 1'b0;
    assign soft_err            = 1'b0;
    assign crc_pass_fail_n     = 1'b1;
    assign crc_valid           = 1'b0;
    assign txp                 = 3'b000;
    assign txn                 = 3'b111;

    // ---- RX tarafi bos (gozlemci modunda cevap uretilmez) ----
    assign m_axi_rx_tdata      = 192'd0;
    assign m_axi_rx_tkeep      = 24'd0;
    assign m_axi_rx_tlast      = 1'b0;
    assign m_axi_rx_tvalid     = 1'b0;
    assign m_axi_ufc_rx_tdata  = 192'd0;
    assign m_axi_ufc_rx_tkeep  = 24'd0;
    assign m_axi_ufc_rx_tlast  = 1'b0;
    assign m_axi_ufc_rx_tvalid = 1'b0;
    assign ufc_in_progress     = 1'b0;

    // ---- Kullanici verisi: her zaman kabul ----
    assign s_axi_tx_tready = 1'b1;

    // ---- UFC TX el sikismasi ----
    // ufc_tx_req'in yukselen kenarinda istek alinir; mesaj boyutu (ufc_tx_ms+1) bayt,
    // 24 baytlik beat'lere bolunur (ms=3 -> 4 bayt -> 1 beat). Beat'ler bitene kadar tready=1.
    reg         req_d     = 1'b0;
    reg         busy      = 1'b0;
    integer     beats_left = 0;
    reg  [7:0]  ms_lat    = 8'd0;
    assign s_axi_ufc_tx_tready = busy;

    integer fd = 0;
    reg [8*64-1:0] fname;
    initial begin
        if (LOG_ENABLE != 0) begin
            $sformat(fname, "aurora_obs_%0s.txt", UNIT_NAME);
            fd = $fopen(fname, "w");
            if (fd == 0) $display("[AURORA %0s] log dosyasi acilamadi", UNIT_NAME);
            else begin
                $fdisplay(fd, "# aurora_64b66b_vip gozlemci logu (birim=%0s). Zamanlar ns.", UNIT_NAME);
                $fflush(fd);
            end
        end
    end

    always @(posedge clk) begin
        req_d <= ufc_tx_req;

        // yeni UFC istegi
        if (ufc_tx_req && !req_d && !busy) begin
            busy       <= 1'b1;
            ms_lat     <= ufc_tx_ms;
            beats_left <= ((ufc_tx_ms + 1) + 23) / 24;
            if (fd != 0) begin
                $fdisplay(fd, "%0d UFC_REQ ms=%0d (%0d bayt)", $time, ufc_tx_ms, ufc_tx_ms + 1);
                $fflush(fd);
            end
        end

        // UFC verisi
        if (s_axi_ufc_tx_tvalid) begin
            if (busy) begin
                if (fd != 0) begin
                    $fdisplay(fd, "%0d UFC_TX tdata=%h", $time, s_axi_ufc_tx_tdata);
                    $fflush(fd);
                end
                if (beats_left <= 1) begin busy <= 1'b0; beats_left <= 0; end
                else                  beats_left <= beats_left - 1;
            end else if (fd != 0) begin
                $fdisplay(fd, "%0d UFC_TX_ISTEKSIZ tdata=%h (ufc_tx_req olmadan veri geldi, yok sayildi)",
                          $time, s_axi_ufc_tx_tdata);
                $fflush(fd);
            end
        end

        // kullanici verisi: yalnizca alt 128 bit anlamli
        if (s_axi_tx_tvalid && s_axi_tx_tready && fd != 0) begin
            $fdisplay(fd, "%0d USER_TX lo128=%h keep=%h last=%0d", $time,
                      s_axi_tx_tdata[127:0], s_axi_tx_tkeep, s_axi_tx_tlast);
            $fflush(fd);
        end
    end

    // ---- link durumu degisimleri ----
    reg cu_d = 1'b0;
    always @(posedge clk) begin
        cu_d <= channel_up;
        if (fd != 0 && channel_up !== cu_d) begin
            $fdisplay(fd, "%0d LINK channel_up=%0d lane_up=%b", $time, channel_up, lane_up);
            $fflush(fd);
        end
    end

`else
    // =================================================================
    // SADE GOVDE (BD ayristirmasi icin): tum cikislar sabit
    // =================================================================
    assign s_axi_tx_tready = 1'b1;
    assign m_axi_rx_tdata = 192'd0;  assign m_axi_rx_tkeep = 24'd0;
    assign m_axi_rx_tlast = 1'b0;    assign m_axi_rx_tvalid = 1'b0;
    assign s_axi_ufc_tx_tready = 1'b0;
    assign m_axi_ufc_rx_tdata = 192'd0; assign m_axi_ufc_rx_tkeep = 24'd0;
    assign m_axi_ufc_rx_tlast = 1'b0;   assign m_axi_ufc_rx_tvalid = 1'b0;
    assign ufc_in_progress = 1'b0;
    assign txp = 3'b000;  assign txn = 3'b111;
    assign gt_refclk1_out = gt_refclk1_p;
    assign hard_err = 1'b0; assign soft_err = 1'b0;
    assign channel_up = 1'b0; assign lane_up = 3'b000;
    assign crc_pass_fail_n = 1'b1; assign crc_valid = 1'b0;
    assign user_clk_out = gt_refclk1_p; assign sync_clk_out = gt_refclk1_p; assign tx_out_clk = gt_refclk1_p;
    assign mmcm_not_locked_out = 1'b1;
    assign gt_pll_lock = 1'b0; assign link_reset_out = 1'b1;
    assign gt_powergood = 3'b000; assign sys_reset_out = 1'b1; assign gt_reset_out = 1'b1;
`endif

endmodule
