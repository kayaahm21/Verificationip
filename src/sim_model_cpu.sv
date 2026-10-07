`timescale 1ns / 1ps

// PCIe UltraScale+ IP yerine konan sadelestirilmis VIP (sim_model_cpu).
// Sadece kullanilan portlar birakildi; VHDL instantiation'i docs/sim_model_cpu_inst.vhd'deki gibi kisaltilmali.
module sim_model_cpu #(
    parameter string INPUT_FILE    = "input_data.txt",  // +TLP_FILE=<dosya> ile de verilebilir
    parameter int    CQ_KEEP_WIDTH = 8,   // m_axis_cq_tkeep genisligi (256-bit icin DWORD basina = 8)
    parameter int    RQ_KEEP_WIDTH = 8    // s_axis_rq_tkeep genisligi
)(
    input  logic                     sys_clk,            // disaridan gelir (VIP'te kullanilmiyor)

    output logic                     user_clk,           // 125 MHz
    output logic                     user_reset,         // aktif yuksek

    // CQ: VIP -> tasarim
    output logic [255:0]             m_axis_cq_tdata,
    output logic [CQ_KEEP_WIDTH-1:0] m_axis_cq_tkeep,
    output logic                     m_axis_cq_tlast,
    input  logic                     m_axis_cq_tready,
    output logic [87:0]              m_axis_cq_tuser,
    output logic                     m_axis_cq_tvalid,

    // RQ: tasarim -> VIP (simdilik sadece ready veriliyor)
    input  logic [255:0]             s_axis_rq_tdata,
    input  logic [RQ_KEEP_WIDTH-1:0] s_axis_rq_tkeep,
    input  logic                     s_axis_rq_tlast,
    output logic                     s_axis_rq_tready,
    input  logic [61:0]              s_axis_rq_tuser,
    input  logic                     s_axis_rq_tvalid,

    // MSI
    input  logic [31:0]              cfg_interrupt_msi_int,
    output logic                     cfg_interrupt_msi_sent,
    output logic                     cfg_interrupt_msi_fail
);
    import cq_vip_pkg::*;

    localparam int KEEP_GRAN = (256/8) / CQ_KEEP_WIDTH;

    // ---- clock / reset / link ----
    initial begin user_clk = 1'b0; forever #4 user_clk = ~user_clk; end   // 125 MHz

    logic user_lnk_up;   // sadece dahili: driver'i reset + link sonrasi baslatir

    initial begin
        user_reset  = 1'b1;
        user_lnk_up = 1'b0;
        repeat (20) @(posedge user_clk);
        user_reset  = 1'b0;
        repeat (20) @(posedge user_clk);
        user_lnk_up = 1'b1;
    end

    // ---- RQ sink ----
    assign s_axis_rq_tready = 1'b1;

    // ---- MSI cevabi: int geldikten 2 clk sonra sent ----
    assign cfg_interrupt_msi_fail = 1'b0;
    logic [1:0] msi_dly;
    always_ff @(posedge user_clk) begin
        msi_dly                <= {msi_dly[0], |cfg_interrupt_msi_int};
        cfg_interrupt_msi_sent <= msi_dly[1] & |cfg_interrupt_msi_int;
    end

    // ---- CQ VIP ----
    axis_tx_if #(.DATA_WIDTH(256), .TUSER_WIDTH(88), .KEEP_GRAN(KEEP_GRAN))
        cq_if (.aclk(user_clk), .rst_n(~user_reset & user_lnk_up));

    assign m_axis_cq_tdata  = cq_if.tdata;
    assign m_axis_cq_tkeep  = cq_if.tkeep;
    assign m_axis_cq_tlast  = cq_if.tlast;
    assign m_axis_cq_tuser  = cq_if.tuser;
    assign m_axis_cq_tvalid = cq_if.tvalid;
    assign cq_if.tready     = m_axis_cq_tready;

    mailbox #(tlp_item) mbx;
    driver  #(256, 88, KEEP_GRAN) drv;
    generator gen;
    string file_name;

    initial begin
        if (!$value$plusargs("TLP_FILE=%s", file_name)) file_name = INPUT_FILE;
        mbx = new();
        drv = new(cq_if, mbx);
        gen = new(mbx, file_name);
        drv.reset();                 // reset kalkisi + link up bekler
        fork drv.run(); join_none
        gen.run();
    end
endmodule
