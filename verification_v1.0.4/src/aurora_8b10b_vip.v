`timescale 1ns / 1ps

// =====================================================================
// aurora_8b10b_vip  (v1.0.4)  -  Aurora 8b/10b IP'sinin (IUB tarafi) yerine konan GOZLEMCI VIP
//
// Hedef: Aurora_aurora_8b10b_0_2 (1 lane, 32 bit AXI-S, Framing, Duplex, UFC YOK) modulunun portlariyla
// ayni portlara sahip olmak. DRP portlari (gt0_drp*) bilerek YOKTUR (IP'de de yoktu; hata kaynagiydi).
//
// Gozlemci davranisi (aurora_64b66b_vip ile ayni mantik):
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
    parameter LINK_UP_CLKS   = 625      // reset'ten sonra channel_up'a kadar user_clk sayisi (~5 us)
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

    // ---- Dahili 125 MHz saat (user_clk girisi BD'deki saat agacindan gelir; mantik buna BAGLI DEGIL) ----
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

    // ---- RX bos (gozlemci: cevap yok) ----
    assign m_axi_rx_tdata  = 32'd0;
    assign m_axi_rx_tkeep  = 4'd0;
    assign m_axi_rx_tvalid = 1'b0;
    assign m_axi_rx_tlast  = 1'b0;

    // ---- Kullanici verisi: her zaman kabul ----
    assign s_axi_tx_tready = 1'b1;

    // ---- Log ----
    integer fd = 0;
    reg [8*64-1:0] fname;
    initial begin
        if (LOG_ENABLE != 0) begin
            $sformat(fname, "aurora8b10b_obs_%0s.txt", UNIT_NAME);
            fd = $fopen(fname, "w");
            $display("[AURORA8B10B %0s] DAVRANIS SURUMU aktif (v1.0.4). Log dosyasi: %0s", UNIT_NAME, fname);
            if (fd == 0) $display("[AURORA8B10B %0s] HATA: log dosyasi acilamadi", UNIT_NAME);
            else begin
                $fdisplay(fd, "# aurora_8b10b_vip gozlemci logu (birim=%0s). Zamanlar ns.", UNIT_NAME);
                $fflush(fd);
            end
        end
    end

    reg cu_d = 1'b0;
    always @(posedge clk) begin
        cu_d <= channel_up;
        if (fd != 0 && channel_up !== cu_d) begin
            $fdisplay(fd, "%0d LINK channel_up=%0d lane_up=%b", $time, channel_up, lane_up);
            $fflush(fd);
        end
        if (s_axi_tx_tvalid && s_axi_tx_tready && fd != 0) begin
            $fdisplay(fd, "%0d USER_TX data=%h keep=%h last=%0d", $time,
                      s_axi_tx_tdata, s_axi_tx_tkeep, s_axi_tx_tlast);
            $fflush(fd);
        end
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
