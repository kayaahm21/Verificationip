`timescale 1ns / 1ps

// =====================================================================
// aurora_64b66b_vip  (v1.0.4, SystemVerilog surumu)  -  ALTERNATIF dosya
//
// src/aurora_64b66b_vip.v ile AYNI modul adi, AYNI portlar, AYNI davranis. Projeye bunlardan
// YALNIZCA BIRINI ekleyin (ikisi birden eklenirse modul adi cakisir).
//   * Once bunu deneyin (SystemVerilog tipinde ekleyin).
//   * BD module reference olarak kabul etmezse src/aurora_64b66b_vip.v'ye donun.
//
// Fark: SystemVerilog yapilari (string/bit/int parametreler, logic, always_ff, $sformatf, function).
// Cevap verme asamasinda sinif/kuyruk eklemek icin bu surum daha uygun bir tabandir.
// Ayrintilar icin src/aurora_64b66b_vip.v basligina bakin.
// =====================================================================
// Davranis varsayilan olarak ACIKTIR (ekstra tanim gerekmez). Yalnizca ayristirma icin sade govde
// istenirse VIP_STUB tanimlanir. (Eski VIP_BEHAVIORAL tanimi da kabul edilir, etkisi yoktur.)
`ifndef VIP_STUB
  `ifndef VIP_BEHAVIORAL
    `define VIP_BEHAVIORAL
  `endif
`endif

module aurora_64b66b_vip #(
    parameter string UNIT_NAME = "shob_1",   // log dosyasi adi: aurora_obs_<UNIT_NAME>.txt
    parameter bit    LOG_ENABLE = 1,          // 0: log yazma
    parameter int    LINK_UP_CLKS = 625        // reset'ten sonra channel_up'a kadar gecen user_clk sayisi (~5 us)
)(
    // ---- TX AXI4-S (USER_DATA_S_AXIS_TX) ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 USER_DATA_S_AXIS_TX TDATA" *)  input  var logic [191:0] s_axi_tx_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 USER_DATA_S_AXIS_TX TLAST" *)  input  var logic         s_axi_tx_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 USER_DATA_S_AXIS_TX TKEEP" *)  input  var logic [23:0]  s_axi_tx_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 USER_DATA_S_AXIS_TX TVALID" *) input  var logic         s_axi_tx_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 USER_DATA_S_AXIS_TX TREADY" *) output var logic         s_axi_tx_tready,

    // ---- RX AXI4-S (USER_DATA_M_AXIS_RX), tready yok ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 USER_DATA_M_AXIS_RX TDATA" *)  output var logic [191:0] m_axi_rx_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 USER_DATA_M_AXIS_RX TLAST" *)  output var logic         m_axi_rx_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 USER_DATA_M_AXIS_RX TKEEP" *)  output var logic [23:0]  m_axi_rx_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 USER_DATA_M_AXIS_RX TVALID" *) output var logic         m_axi_rx_tvalid,

    // ---- UFC TX (UFC_S_AXIS_TX): tkeep/tlast yok ----
    input  var logic         ufc_tx_req,
    input  var logic [7:0]   ufc_tx_ms,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 UFC_S_AXIS_TX TDATA" *)  input  var logic [191:0] s_axi_ufc_tx_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 UFC_S_AXIS_TX TVALID" *) input  var logic         s_axi_ufc_tx_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 UFC_S_AXIS_TX TREADY" *) output var logic         s_axi_ufc_tx_tready,

    // ---- UFC RX (UFC_M_AXIS_RX), tready yok ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 UFC_M_AXIS_RX TDATA" *)  output var logic [191:0] m_axi_ufc_rx_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 UFC_M_AXIS_RX TKEEP" *)  output var logic [23:0]  m_axi_ufc_rx_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 UFC_M_AXIS_RX TLAST" *)  output var logic         m_axi_ufc_rx_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 UFC_M_AXIS_RX TVALID" *) output var logic         m_axi_ufc_rx_tvalid,
    output var logic         ufc_in_progress,

    // ---- GT seri I/O ----
    input  var logic [0:2]   rxp,
    input  var logic [0:2]   rxn,
    output var logic [0:2]   txp,
    output var logic [0:2]   txn,

    // ---- GT referans saati ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:diff_clock:1.0 GT_DIFF_REFCLK1 CLK_P",
       X_INTERFACE_PARAMETER = "FREQ_HZ 250000000" *)
    input  var logic         gt_refclk1_p,
    (* X_INTERFACE_INFO = "xilinx.com:interface:diff_clock:1.0 GT_DIFF_REFCLK1 CLK_N" *)
    input  var logic         gt_refclk1_n,
    output var logic         gt_refclk1_out,

    // ---- Hata / durum ----
    output var logic         hard_err,
    output var logic         soft_err,
    output var logic         channel_up,
    output var logic [0:2]   lane_up,
    output var logic         crc_pass_fail_n,
    output var logic         crc_valid,

    // ---- Sistem arayuzu ----
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 user_clk_out CLK",
       X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF USER_DATA_S_AXIS_TX:USER_DATA_M_AXIS_RX:UFC_S_AXIS_TX:UFC_M_AXIS_RX, FREQ_HZ 125000000" *)
    output var logic         user_clk_out,
    output var logic         mmcm_not_locked_out,
    output var logic         sync_clk_out,
    input  var logic         reset_pb,
    input  var logic         gt_rxcdrovrden_in,
    input  var logic         power_down,
    input  var logic [2:0]   loopback,
    input  var logic         pma_init,
    output var logic         gt_pll_lock,

    input  var logic         init_clk,
    output var logic         link_reset_out,
    output var logic [2:0]   gt_powergood,
    output var logic         sys_reset_out,
    output var logic         gt_reset_out,
    output var logic         tx_out_clk
);

`ifdef VIP_BEHAVIORAL
    // ---- 125 MHz kullanici saati ----
    logic clk = 1'b0;
    always #4 clk = ~clk;                     // 8 ns periyot
    assign user_clk_out   = clk;
    assign sync_clk_out   = clk;
    assign tx_out_clk     = clk;
    assign gt_refclk1_out = gt_refclk1_p;

    // ---- Link modeli: ok=1 iken sayac ilerler; reset_pb/pma_init/power_down sifirlar ----
    int   cnt = 0;
    logic ok;
    assign ok = !(reset_pb === 1'b1 || pma_init === 1'b1 || power_down === 1'b1);
    always_ff @(posedge clk) begin
        if (!ok)                 cnt <= 0;
        else if (cnt < 1000000)  cnt <= cnt + 1;
    end

    assign gt_powergood        = (cnt >= 5)  ? 3'b111 : 3'b000;
    assign gt_pll_lock         = (cnt >= 8);
    assign gt_reset_out        = (cnt < 10);                 // aktif yuksek
    assign sys_reset_out       = (cnt < 20);                 // aktif yuksek
    assign mmcm_not_locked_out = (cnt < 4);
    assign channel_up          = (cnt >= LINK_UP_CLKS);
    assign lane_up             = channel_up ? 3'b111 : 3'b000;
    assign link_reset_out      = ~channel_up;
    assign hard_err            = 1'b0;
    assign soft_err            = 1'b0;
    assign crc_pass_fail_n     = 1'b1;
    assign crc_valid           = 1'b0;
    assign txp                 = 3'b000;
    assign txn                 = 3'b111;

    // ---- RX tarafi bos (gozlemci: cevap yok) ----
    assign m_axi_rx_tdata      = '0;
    assign m_axi_rx_tkeep      = '0;
    assign m_axi_rx_tlast      = 1'b0;
    assign m_axi_rx_tvalid     = 1'b0;
    assign m_axi_ufc_rx_tdata  = '0;
    assign m_axi_ufc_rx_tkeep  = '0;
    assign m_axi_ufc_rx_tlast  = 1'b0;
    assign m_axi_ufc_rx_tvalid = 1'b0;
    assign ufc_in_progress     = 1'b0;

    assign s_axi_tx_tready = 1'b1;

    // ---- UFC TX el sikismasi: istek kenari -> busy (tready) -> beat'ler bitince birakir ----
    logic req_d = 1'b0;
    logic busy  = 1'b0;
    int   beats_left = 0;
    assign s_axi_ufc_tx_tready = busy;

    int fd = 0;
    initial begin
        if (LOG_ENABLE) begin
            fd = $fopen($sformatf("aurora_obs_%s.txt", UNIT_NAME), "w");
            $display("[AURORA %s] DAVRANIS SURUMU aktif (v1.0.4). Log dosyasi: aurora_obs_%s.txt", UNIT_NAME, UNIT_NAME);
            if (fd == 0) $display("[AURORA %s] HATA: log dosyasi acilamadi", UNIT_NAME);
            else begin
                $fdisplay(fd, "# aurora_64b66b_vip gozlemci logu (birim=%s). Zamanlar ns.", UNIT_NAME);
                $fflush(fd);
            end
        end
    end

    // log satiri yazar (fd acik degilse sessizce atlar)
    function automatic void log_line(string s);
        if (fd != 0) begin
            $fdisplay(fd, "%0d %s", $time, s);
            $fflush(fd);
        end
    endfunction

    always @(posedge clk) begin
        req_d <= ufc_tx_req;

        if (ufc_tx_req && !req_d && !busy) begin
            busy       <= 1'b1;
            beats_left <= (int'(ufc_tx_ms) + 1 + 23) / 24;
            log_line($sformatf("UFC_REQ ms=%0d (%0d bayt)", ufc_tx_ms, int'(ufc_tx_ms) + 1));
        end

        if (s_axi_ufc_tx_tvalid) begin
            if (busy) begin
                log_line($sformatf("UFC_TX tdata=%h", s_axi_ufc_tx_tdata));
                if (beats_left <= 1) begin busy <= 1'b0; beats_left <= 0; end
                else                  beats_left <= beats_left - 1;
            end else
                log_line($sformatf("UFC_TX_ISTEKSIZ tdata=%h (ufc_tx_req olmadan veri geldi, yok sayildi)",
                                   s_axi_ufc_tx_tdata));
        end

        // kullanici verisi: yalnizca alt 128 bit anlamli
        if (s_axi_tx_tvalid && s_axi_tx_tready)
            log_line($sformatf("USER_TX lo128=%h keep=%h last=%0d",
                               s_axi_tx_tdata[127:0], s_axi_tx_tkeep, s_axi_tx_tlast));
    end

    logic cu_d = 1'b0;
    always @(posedge clk) begin
        cu_d <= channel_up;
        if (channel_up !== cu_d)
            log_line($sformatf("LINK channel_up=%0d lane_up=%b", channel_up, lane_up));
    end

`else
    // ---- SADE GOVDE (VIP_STUB): tum cikislar sabit ----
    initial $display("[AURORA] UYARI: SADE GOVDE (VIP_STUB) aktif - saat/link/log YOK.");
    assign s_axi_tx_tready = 1'b1;
    assign m_axi_rx_tdata = '0;  assign m_axi_rx_tkeep = '0;
    assign m_axi_rx_tlast = 1'b0; assign m_axi_rx_tvalid = 1'b0;
    assign s_axi_ufc_tx_tready = 1'b0;
    assign m_axi_ufc_rx_tdata = '0; assign m_axi_ufc_rx_tkeep = '0;
    assign m_axi_ufc_rx_tlast = 1'b0; assign m_axi_ufc_rx_tvalid = 1'b0;
    assign ufc_in_progress = 1'b0;
    assign txp = 3'b000; assign txn = 3'b111;
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
