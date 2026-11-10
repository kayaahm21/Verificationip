-----------------------------------------------------------------------
-- sim_model_rsi (VIP) instantiation  -  v1.0.7
--
-- RSI modelini Top/PcieTop icinde SIM_MODE ile ornekleme SABLONU. Top.vhd / PcieTop.vhd tasarimciya aittir;
-- bu blogu siz (tasarimci) ekleyeceksiniz. Sinyal adlari TASLAKTIR (<...>): kendi tasarimdaki pcie_ip_rsi1..3
-- cagrilarinin yanindaki gercek sinyal adlariyla degistirin.
--
-- Her RSI icin AYRI bir sim_model_rsi ornegi gerekir (RSI_ID = 1, 2, 3).
-- Portlar sim_model_cpu ile ayni; farklar:
--   * CQ tarafi bostur (m_axis_cq_* hep 0; m_axis_cq_tready girisi yok sayilir) - RSI'ye CPU->FPGA trafigi yok
--   * huzme_basi_gen hep '0', huzme_basi_obs yok sayilir
--   * senaryo dosyasi okumaz; RSI baslangic adresi / offset / huzme sayilari CPU VIP surucusunden (cpu_pkg ortak
--     degiskenleri) gelir, bu yuzden sim_model_cpu (senaryo suren CPU VIP) AYNI simulasyonda bulunmali
-----------------------------------------------------------------------

-- ---- architecture govdesinde (RSI1 icin; RSI2/RSI3 icin RSI_ID ve sinyal adlarini degistirin) ----
gen_sim_model_rsi1: if (SIM_MODE = TRUE) generate
begin
    inst_sim_model_rsi1 : entity xil_defaultlib.sim_model_rsi
    GENERIC MAP (
        RSI_ID         => 1,                 -- 1..3
        OUT_PREFIX     => "rsi_out",         -- cikti: rsi_out_rsi1.txt (RSI2/3 icin rsi_out_rsi2.txt, ...)
        ISR_LATENCY_NS => 100,               -- MSI'dan sonra ISR gecikmesi
        DETAIL_LINES   => 64                 -- cikti dosyasina yazilan en fazla ornek satiri (-1: hepsi)
    )
    PORT MAP (
        sys_clk                 => <rsi1_pcie_sys_clk>,

        user_clk                => <clk_user_rsi1_pcie>,
        user_reset              => <rst_user_rsi1_pcie>,

        s_axis_rq_tdata         => <rsi1_s_axis_rq_tdata>,
        s_axis_rq_tkeep         => <rsi1_s_axis_rq_tkeep>,     -- 8 bit (256-bit RQ)
        s_axis_rq_tlast         => <rsi1_s_axis_rq_tlast>,
        s_axis_rq_tready        => <rsi1_s_axis_rq_tready>,    -- std_logic_vector(3 downto 0)
        s_axis_rq_tuser         => <rsi1_s_axis_rq_tuser>,
        s_axis_rq_tvalid        => <rsi1_s_axis_rq_tvalid>,

        m_axis_cq_tdata         => open,
        m_axis_cq_tkeep         => open,
        m_axis_cq_tlast         => open,
        m_axis_cq_tready        => '1',
        m_axis_cq_tuser         => open,
        m_axis_cq_tvalid        => open,

        cfg_interrupt_msi_int   => <cfg_interrupt_msi_int_rsi1>,   -- MSI1..MSI4 = bit 0..3
        cfg_interrupt_msi_sent  => <cfg_interrupt_msi_sent_rsi1>,
        cfg_interrupt_msi_fail  => open,

        huzme_basi_obs          => '0',
        huzme_basi_gen          => open
    );
end generate gen_sim_model_rsi1;
