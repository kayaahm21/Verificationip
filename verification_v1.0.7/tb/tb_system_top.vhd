-- Tum sistemi (Top) iceren ust seviye testbench.
-- VIP, Top icindeki gen_sim_model_cpu (SIM_MODE=TRUE) ile devreye girer; user_clk'i ve
-- PCIe trafigini o uretir. Bu TB sadece dis dunyayi (refclk'ler, tie-off'lar) saglar.
--
-- !! Port isimleri ekran goruntusunden (OCR) okundu; bazilari belirsiz. Top.vhd ile
-- !! karsilastirip duzeltin. "TODO" satirlarina ozellikle bakin.
library ieee;
use ieee.std_logic_1164.all;

library xil_defaultlib;
-- use xil_defaultlib.<paket_adi>.all;   -- TODO: NUM_OF_GT_QUADS / NUM_OF_AURORA_CORES hangi pakette?

entity tb_system_top is
end tb_system_top;

architecture sim of tb_system_top is

    -- TODO: Top.vhd'deki gercek degerlerle esle (paketten geliyorsa bu iki satiri silip paketi use et)
    constant NUM_OF_GT_QUADS    : integer := 1;
    constant NUM_OF_AURORA_CORES: integer := 1;

    constant SIM_TIME : time := 2 ms;

    -- refclk'ler
    signal clk_pcie_100  : std_logic := '0';   -- PCIe refclk (100 MHz)
    signal clk_aurora    : std_logic := '0';   -- Aurora refclk (156.25 MHz; IP ayarina gore degistir)

    signal rasim_refclk  : std_logic_vector(NUM_OF_GT_QUADS-1 downto 0);
    signal rasim_refclk_n: std_logic_vector(NUM_OF_GT_QUADS-1 downto 0);

    -- cikislar (acik birakilacaklar)
    signal refclk_buffer_clk_sel : std_logic;
    signal qsfp_mod_sel_n, qsfp_rst_n : std_logic_vector(7 downto 0);
    signal rasim_tx_p, rasim_tx_n : std_logic_vector(NUM_OF_AURORA_CORES-1 downto 0);
    signal sam_tx_p, sam_tx_n     : std_logic_vector(1 downto 0);
    signal rsy_tx_p, rsy_tx_n     : std_logic_vector(3 downto 0);
    signal rsi_tx_p, rsi_tx_n     : std_logic_vector(3 downto 0);
    signal gk_1_tx, gk_2_tx, gk_3_tx : std_logic;
    signal enc_clk, enc_acp, enc_arp : std_logic;
    signal iukk_pin_reset, iukk_pin_reset_dir, iukk_mlvds_failsafe_en : std_logic;
    signal fpga_led : std_logic;

    -- I2C hatlari: pull-up
    signal i2c_tempsensor_scl, i2c_tempsensor_sda : std_logic := 'H';
    signal i2c_qsfp_scl, i2c_qsfp_sda             : std_logic := 'H';
    signal i2c_ipmi_scl, i2c_ipmi_sda             : std_logic := 'H';   -- TODO: ekran goruntusunde kesik

begin

    -- ---------------------------------------------------------------
    -- Clock uretimi
    -- ---------------------------------------------------------------
    clk_pcie_100 <= not clk_pcie_100 after 5 ns;       -- 100 MHz
    clk_aurora   <= not clk_aurora   after 3.2 ns;     -- 156.25 MHz

    rasim_refclk   <= (others => clk_aurora);
    rasim_refclk_n <= (others => not clk_aurora);

    -- ---------------------------------------------------------------
    -- DUT
    -- ---------------------------------------------------------------
    dut : entity xil_defaultlib.Top
        generic map (
            SIM_MODE => TRUE            -- VIP'i (gen_sim_model_cpu) aktif eder
        )
        port map (
            REFCLK_BUFFER_CLK_SEL => refclk_buffer_clk_sel,
            QSFP_MOD_SEL_N        => qsfp_mod_sel_n,
            QSFP_RST_N            => qsfp_rst_n,
            QSFP_MOD_PRESENT_N    => (others => '1'),

            RASIM_GT_REFCLK_P     => rasim_refclk,
            RASIM_GT_REFCLK_N     => rasim_refclk_n,
            RASIM_GT_TX_P         => rasim_tx_p,
            RASIM_GT_TX_N         => rasim_tx_n,
            RASIM_GT_RX_P         => (others => '0'),
            RASIM_GT_RX_N         => (others => '1'),

            SAM_GT_REFCLK_P       => clk_aurora,
            SAM_GT_REFCLK_N       => not clk_aurora,
            SAM_GT_TX_P           => sam_tx_p,
            SAM_GT_TX_N           => sam_tx_n,
            SAM_GT_RX_P           => (others => '0'),
            SAM_GT_RX_N           => (others => '1'),

            RSY_PCIE_GT_REFCLK_P  => clk_pcie_100,
            RSY_PCIE_GT_REFCLK_N  => not clk_pcie_100,
            RSY_PCIE_GT_TXP       => rsy_tx_p,
            RSY_PCIE_GT_TXN       => rsy_tx_n,
            RSY_PCIE_GT_RXP       => (others => '0'),
            RSY_PCIE_GT_RXN       => (others => '1'),

            RSI_PCIE_GT_REFCLK_P  => clk_pcie_100,
            RSI_PCIE_GT_REFCLK_N  => not clk_pcie_100,
            RSI_PCIE_GT_TXP       => rsi_tx_p,
            RSI_PCIE_GT_TXN       => rsi_tx_n,
            RSI_PCIE_GT_RXP       => (others => '0'),
            RSI_PCIE_GT_RXN       => (others => '1'),

            I2C_TEMPSENSOR_SCL_IO => i2c_tempsensor_scl,
            I2C_TEMPSENSOR_SDA_IO => i2c_tempsensor_sda,
            I2C_QSFP_SCL_IO       => i2c_qsfp_scl,
            I2C_QSFP_SDA_IO       => i2c_qsfp_sda,
            I2C_IPMI_SCL_IO       => i2c_ipmi_scl,
            I2C_IPMI_SDA_IO       => i2c_ipmi_sda,

            GK_1_RS422_RX         => '1',     -- UART bosta '1'
            GK_1_RS422_TX         => gk_1_tx,
            GK_2_RS422_RX         => '1',
            GK_2_RS422_TX         => gk_2_tx,
            GK_3_RS422_RX         => '1',
            GK_3_RS422_TX         => gk_3_tx,

            ENC_RS422_CLK         => enc_clk,
            ENC_RS422_DATA        => '0',
            ENC_RS422_ACP         => enc_acp,
            ENC_RS422_ARP         => enc_arp,

            IUKK_PIN_RESET        => iukk_pin_reset,
            IUKK_PIN_RESET_DIR    => iukk_pin_reset_dir,
            IUKK_MLVDS_FAILSAFE_EN=> iukk_mlvds_failsafe_en,

            KHJ_ALARM             => '0',
            GCB_DC_ON_OFF         => '0',
            GCB_AC_ON_OFF         => '0',
            FPGA_LED              => fpga_led,

            VPX_GAB_N             => '1',     -- TODO: gercek port adlari (GA0..GA4/GAP?) kontrol et
            VPX_GAI_N             => '1',
            VPX_GAP_N             => '1'
        );

    -- ---------------------------------------------------------------
    -- Bitis (VHDL-2008: dosya ozelliginde VHDL 2008 secili olmali)
    -- ---------------------------------------------------------------
    process
    begin
        wait for SIM_TIME;
        report "[TB_SYSTEM] Simulasyon suresi doldu." severity note;
        std.env.finish;
    end process;

end sim;
