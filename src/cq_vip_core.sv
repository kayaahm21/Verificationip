`timescale 1ns / 1ps

// PCIe UltraScale+ (256-bit) IP'nin CQ tarafini taklit eden cekirdek.
// sim_model_cpu.sv bu modulu instantiate edip IP'nin geri kalan portlarini baglayacak.
module cq_vip_core #(
    parameter string INPUT_FILE   = "input_data.txt",
    parameter int    LINK_UP_NS   = 200
)(
    // user_clk / user_reset / link
    output logic         user_clk,
    output logic         user_reset,   // aktif yuksek (gercek IP gibi)
    output logic         user_lnk_up,

    // CQ (VIP -> tasarim)
    output logic [255:0] m_axis_cq_tdata,
    output logic [7:0]   m_axis_cq_tkeep,
    output logic         m_axis_cq_tlast,
    input  logic         m_axis_cq_tready,
    output logic [87:0]  m_axis_cq_tuser,
    output logic         m_axis_cq_tvalid,

    // RQ (tasarim -> VIP): simdilik hep ready
    input  logic         s_axis_rq_tvalid,
    output logic         s_axis_rq_tready,

    // MSI
    input  logic [31:0]  cfg_interrupt_msi_int,
    output logic         cfg_interrupt_msi_sent,
    output logic         cfg_interrupt_msi_fail
);
    import cq_vip_pkg::*;

    // ---- clock / reset / link ----
    logic rst_n;
    initial begin user_clk = 1'b0; forever #2 user_clk = ~user_clk; end   // 250 MHz
    initial begin
        rst_n = 1'b0; user_lnk_up = 1'b0;
        #100 rst_n = 1'b1;
        #(LINK_UP_NS) user_lnk_up = 1'b1;
    end
    assign user_reset = ~rst_n;

    // ---- RQ sink / MSI cevabi ----
    assign s_axis_rq_tready       = 1'b1;
    assign cfg_interrupt_msi_fail = 1'b0;
    logic [1:0] msi_dly;
    always_ff @(posedge user_clk) begin
        msi_dly <= {msi_dly[0], |cfg_interrupt_msi_int};
        cfg_interrupt_msi_sent <= msi_dly[1] & |cfg_interrupt_msi_int;
    end

    // ---- VIP ----
    axis_tx_if #(.DATA_WIDTH(256), .TUSER_WIDTH(88), .KEEP_GRAN(4)) cq_if (user_clk, rst_n & user_lnk_up);

    assign m_axis_cq_tdata  = cq_if.tdata;
    assign m_axis_cq_tkeep  = cq_if.tkeep;
    assign m_axis_cq_tlast  = cq_if.tlast;
    assign m_axis_cq_tuser  = cq_if.tuser;
    assign m_axis_cq_tvalid = cq_if.tvalid;
    assign cq_if.tready     = m_axis_cq_tready;

    mailbox #(tlp_item) mbx;
    driver  #(256, 88, 4) drv;
    generator gen;
    string file_name;

    initial begin
        if (!$value$plusargs("TLP_FILE=%s", file_name)) file_name = INPUT_FILE;
        mbx = new();
        drv = new(cq_if, mbx);
        gen = new(mbx, file_name);
        drv.reset();                  // reset + link up bekler
        fork drv.run(); join_none
        gen.run();
    end
endmodule
