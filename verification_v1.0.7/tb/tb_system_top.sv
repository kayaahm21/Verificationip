`timescale 1ns / 1ps

// Tum sistemi (Top) iceren ust seviye testbench - SystemVerilog surumu.
// VIP, Top icindeki gen_sim_model_cpu (SIM_MODE=TRUE) ile devreye girer; user_clk'i ve
// PCIe trafigini o uretir. Bu TB sadece dis dunyayi (refclk'ler, tie-off'lar) saglar.
//
// !! Port isimleri ekran goruntusunden (OCR) okundu; bazilari belirsiz. Top.vhd ile
// !! karsilastirip duzeltin. Verilog buyuk/kucuk harfe duyarlidir: isimleri VHDL'deki
// !! yazilisla birebir kullanin.
module tb_system_top;

    // TODO: Top.vhd'deki gercek degerlerle esle
    localparam int NUM_OF_GT_QUADS     = 1;
    localparam int NUM_OF_AURORA_CORES = 1;

    localparam time SIM_TIME = 2ms;

    // ---------------------------------------------------------------
    // Clock uretimi
    // ---------------------------------------------------------------
    logic clk_pcie_100 = 1'b0;   // PCIe refclk 100 MHz
    logic clk_aurora   = 1'b0;   // Aurora refclk 156.25 MHz (IP ayarina gore degistir)

    always #5.0 clk_pcie_100 = ~clk_pcie_100;
    always #3.2 clk_aurora   = ~clk_aurora;

    // ---------------------------------------------------------------
    // Cikislar (bos birakilanlar)
    // ---------------------------------------------------------------
    logic                              refclk_buffer_clk_sel;
    logic [7:0]                        qsfp_mod_sel_n, qsfp_rst_n;
    logic [NUM_OF_AURORA_CORES-1:0]    rasim_tx_p, rasim_tx_n;
    logic [1:0]                        sam_tx_p, sam_tx_n;
    logic [3:0]                        rsy_tx_p, rsy_tx_n;
    logic [3:0]                        rsi_tx_p, rsi_tx_n;
    logic                              gk_1_tx, gk_2_tx, gk_3_tx;
    logic                              enc_clk, enc_acp, enc_arp;
    logic                              iukk_pin_reset, iukk_pin_reset_dir, iukk_mlvds_failsafe_en;
    logic                              fpga_led;

    // I2C hatlari: pull-up
    tri1 i2c_tempsensor_scl, i2c_tempsensor_sda;
    tri1 i2c_qsfp_scl,       i2c_qsfp_sda;
    tri1 i2c_ipmi_scl,       i2c_ipmi_sda;      // TODO: ekran goruntusunde kesik

    // ---------------------------------------------------------------
    // DUT (VHDL entity Top)
    // ---------------------------------------------------------------
    Top #(
        .SIM_MODE (1)               // VIP'i (gen_sim_model_cpu) aktif eder
    ) dut (
        .REFCLK_BUFFER_CLK_SEL (refclk_buffer_clk_sel),
        .QSFP_MOD_SEL_N        (qsfp_mod_sel_n),
        .QSFP_RST_N            (qsfp_rst_n),
        .QSFP_MOD_PRESENT_N    ({8{1'b1}}),

        .RASIM_GT_REFCLK_P     ({NUM_OF_GT_QUADS{clk_aurora}}),
        .RASIM_GT_REFCLK_N     ({NUM_OF_GT_QUADS{~clk_aurora}}),
        .RASIM_GT_TX_P         (rasim_tx_p),
        .RASIM_GT_TX_N         (rasim_tx_n),
        .RASIM_GT_RX_P         ('0),
        .RASIM_GT_RX_N         ('1),

        .SAM_GT_REFCLK_P       (clk_aurora),
        .SAM_GT_REFCLK_N       (~clk_aurora),
        .SAM_GT_TX_P           (sam_tx_p),
        .SAM_GT_TX_N           (sam_tx_n),
        .SAM_GT_RX_P           ('0),
        .SAM_GT_RX_N           ('1),

        .RSY_PCIE_GT_REFCLK_P  (clk_pcie_100),
        .RSY_PCIE_GT_REFCLK_N  (~clk_pcie_100),
        .RSY_PCIE_GT_TXP       (rsy_tx_p),
        .RSY_PCIE_GT_TXN       (rsy_tx_n),
        .RSY_PCIE_GT_RXP       ('0),
        .RSY_PCIE_GT_RXN       ('1),

        .RSI_PCIE_GT_REFCLK_P  (clk_pcie_100),
        .RSI_PCIE_GT_REFCLK_N  (~clk_pcie_100),
        .RSI_PCIE_GT_TXP       (rsi_tx_p),
        .RSI_PCIE_GT_TXN       (rsi_tx_n),
        .RSI_PCIE_GT_RXP       ('0),
        .RSI_PCIE_GT_RXN       ('1),

        .I2C_TEMPSENSOR_SCL_IO (i2c_tempsensor_scl),
        .I2C_TEMPSENSOR_SDA_IO (i2c_tempsensor_sda),
        .I2C_QSFP_SCL_IO       (i2c_qsfp_scl),
        .I2C_QSFP_SDA_IO       (i2c_qsfp_sda),
        .I2C_IPMI_SCL_IO       (i2c_ipmi_scl),
        .I2C_IPMI_SDA_IO       (i2c_ipmi_sda),

        .GK_1_RS422_RX         (1'b1),     // UART bosta '1'
        .GK_1_RS422_TX         (gk_1_tx),
        .GK_2_RS422_RX         (1'b1),
        .GK_2_RS422_TX         (gk_2_tx),
        .GK_3_RS422_RX         (1'b1),
        .GK_3_RS422_TX         (gk_3_tx),

        .ENC_RS422_CLK         (enc_clk),
        .ENC_RS422_DATA        (1'b0),
        .ENC_RS422_ACP         (enc_acp),
        .ENC_RS422_ARP         (enc_arp),

        .IUKK_PIN_RESET         (iukk_pin_reset),
        .IUKK_PIN_RESET_DIR     (iukk_pin_reset_dir),
        .IUKK_MLVDS_FAILSAFE_EN (iukk_mlvds_failsafe_en),

        .KHJ_ALARM             (1'b0),
        .GCB_DC_ON_OFF         (1'b0),
        .GCB_AC_ON_OFF         (1'b0),
        .FPGA_LED              (fpga_led),

        .VPX_GAB_N             (1'b1),     // TODO: gercek port adlari (GA0..GA4/GAP?) kontrol et
        .VPX_GAI_N             (1'b1),
        .VPX_GAP_N             (1'b1)
    );

    // ---------------------------------------------------------------
    // Bitis
    // ---------------------------------------------------------------
    initial begin
        #(SIM_TIME);
        $display("[TB_SYSTEM] Simulasyon suresi doldu.");
        $finish;
    end

endmodule
