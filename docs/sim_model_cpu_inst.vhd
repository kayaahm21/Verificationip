-----------------------------------------------------------------------
-- Generate sim model cpu instantiation (sadelestirilmis)
-----------------------------------------------------------------------
gen_sim_model_cpu: if (SIM_MODE = TRUE) generate
begin
    inst_sim_model_cpu : entity xil_defaultlib.sim_model_cpu
    PORT MAP (
        sys_clk                 => cpu_pcie_sys_clk,

        user_clk                => clk_user_cpu_pcie,
        user_reset              => rst_user_cpu_pcie,
        user_lnk_up             => cdc_lnk_up_cpu_pcie,
        phy_rdy_out             => cdc_cpu_pcie_phy_rdy_out,
        cfg_local_error_out     => ila_debug_cpu_cfg_local_error_out,

        s_axis_rq_tdata         => cdc_cpu_s_axis_rq.tdata,
        s_axis_rq_tkeep         => buf_cpu_s_axis_rq_tkeep,
        s_axis_rq_tlast         => cdc_cpu_s_axis_rq.tlast,
        s_axis_rq_tready        => buf_cpu_s_axis_rq_tready,
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
        cfg_interrupt_msi_fail  => pulse_debug_cpu_msi_fail
    );
end generate gen_sim_model_cpu;
