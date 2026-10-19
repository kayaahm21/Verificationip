-----------------------------------------------------------------------
-- sim_model_cpu (VIP) instantiation  -  v1.0.3
--
-- Bu blok PcieTop.vhd icindeki eski (yorum satirli) gen_sim_model_cpu blogunun yerine gecer.
-----------------------------------------------------------------------

-- ---- architecture bildirim bolumune eklenecek ----
-- signal huzme_basi_gen_sig : std_logic;     -- VIP'in urettigi HB (SCRIPT modunda)

-- ---- architecture govdesinde ----
gen_sim_model_cpu: if (SIM_MODE = TRUE) generate
begin
    inst_sim_model_cpu : entity xil_defaultlib.sim_model_cpu
    -- Istege bagli generic'ler (hepsinin varsayilani vardir; yorumu acip degistirebilirsiniz):
    -- GENERIC MAP (
    --     INPUT_FILE      => "input_data.txt",   -- senaryo dosyasi
    --     BEAM_SOURCE     => "SCRIPT",           -- "SCRIPT": HB'yi VIP uretir, "DESIGN": gercek modul uretir
    --     BEAM_PULSE_CLKS => 1,                  -- uretilen HB darbesinin genisligi (clock)
    --     OUT_FILE        => "cpu_out.txt",      -- v1.0.3: islemcinin ayristirdigi mesajlar
    --     TRACE_FILE      => "rq_trace.txt",     -- v1.0.3: gelen tum TLP'lerin izi
    --     ISR_LATENCY_NS  => 100                 -- v1.0.3: MSI'dan sonra ISR gecikmesi
    -- )
    PORT MAP (
        sys_clk                 => cpu_pcie_sys_clk,

        user_clk                => clk_user_cpu_pcie,
        user_reset              => rst_user_cpu_pcie,

        s_axis_rq_tdata         => cdc_cpu_s_axis_rq.tdata,
        s_axis_rq_tkeep         => buf_cpu_s_axis_rq_tkeep,
        s_axis_rq_tlast         => cdc_cpu_s_axis_rq.tlast,
        s_axis_rq_tready        => buf_cpu_s_axis_rq_tready,   -- std_logic_vector(3 downto 0)
        -- v1.0.3: s_axis_rq_* artik islemci modeli tarafindan tuketilir (FPGA'nin hafizaya yazdigi TLP'ler)
        s_axis_rq_tuser         => cdc_cpu_s_axis_rq_tuser,
        s_axis_rq_tvalid        => cdc_cpu_s_axis_rq.tvalid,

        m_axis_cq_tdata         => cdc_cpu_m_axis_cq.tdata,
        m_axis_cq_tkeep         => buf_cpu_m_axis_cq_tkeep,
        m_axis_cq_tlast         => cdc_cpu_m_axis_cq.tlast,
        m_axis_cq_tready        => cdc_cpu_m_axis_cq_tready,
        m_axis_cq_tuser         => open,
        m_axis_cq_tvalid        => cdc_cpu_m_axis_cq.tvalid,

        cfg_interrupt_msi_int   => cfg_interrupt_msi_int_cpu,
        cfg_interrupt_msi_sent  => cfg_interrupt_msi_sent_cpu,
        cfg_interrupt_msi_fail  => pulse_debug_cpu_msi_fail,

        -- Huzme basi: VIP tasarimdaki HB telini IZLER, senaryo modunda URETIR
        huzme_basi_obs          => HuzmeBasi,
        huzme_basi_gen          => huzme_basi_gen_sig
    );

    -- ===== SENARYO MODU (HB'yi VIP uretir) =====
    -- HuzmeBasi'yi suren baska bir modul yokken kullanilir.
    -- NOT: HuzmeBasi PcieTop'un GIRIS portuysa bu atama burada yapilamaz;
    --      HB'nin uretildigi ust seviyede yapilmalidir.
    HuzmeBasi <= huzme_basi_gen_sig;

    -- ===== GERCEK MODUL BAGLANDIGINDA =====
    -- 1) Yukaridaki  "HuzmeBasi <= huzme_basi_gen_sig;"  satirini SIL (cift surucu olmasin)
    -- 2) huzme_basi_gen => open  yap
    -- 3) VIP'te BEAM_SOURCE="DESIGN" sec (generic veya +BEAM_SOURCE=DESIGN)
end generate gen_sim_model_cpu;
