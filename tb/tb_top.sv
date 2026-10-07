`timescale 1ns / 1ps

// design_1_wrapper (kisaltilmis test yolu) icin bagimsiz TB.
// Wrapper S_AXIS_0: 256-bit tdata, 32-bit tkeep (bayt), 16-bit tuser.
module tb_top();
    import cq_vip_pkg::*;

    localparam int DATA_WIDTH  = 256;
    localparam int TUSER_WIDTH = 16;
    localparam int KEEP_GRAN   = 1;

    logic clk;
    logic rst_n;

    mailbox #(tlp_item) mbx;
    driver  #(DATA_WIDTH, TUSER_WIDTH, KEEP_GRAN) drv;
    generator gen;

    axis_tx_if #(DATA_WIDTH, TUSER_WIDTH, KEEP_GRAN) s_axis_if (clk, rst_n);

    design_1_wrapper dut (
        .s_axis_aclk_0    (clk),
        .s_axis_aresetn_0 (rst_n),
        .S_AXIS_0_tdata   (s_axis_if.tdata),
        .S_AXIS_0_tkeep   (s_axis_if.tkeep),
        .S_AXIS_0_tlast   (s_axis_if.tlast),
        .S_AXIS_0_tready  (s_axis_if.tready),
        .S_AXIS_0_tstrb   (s_axis_if.tkeep),
        .S_AXIS_0_tuser   (s_axis_if.tuser),
        .S_AXIS_0_tvalid  (s_axis_if.tvalid),
        .ConfigSettings_Config_V_0_tready                 (1'b1),
        .DebugMsgReceived_Flag_V_0_tready                 (1'b1),
        .DebugOku_Flag_V_0_tready                         (1'b1),
        .HuzparReceived_Flag_V_0_tready                   (1'b1),
        .KonfigurasyonAyarReceived_Flag_V_0_tready        (1'b1),
        .MessageStartedFinished_Flag_V_0_tready           (1'b1),
        .MsiHandler_Config_V_0_tready                     (1'b1),
        .PcieAdresAtamaReceived_Flag_V_0_tready           (1'b1),
        .RasimTxUfcMsgHandler_Param_V_0_tready            (1'b1),
        .RasimUserRxDataHandlerRsiHeader_Param_V_0_tready (1'b1),
        .RasimUserRxDataHandler_Param_V_0_tready          (1'b1),
        .Rasim_CircularBuffer_Config_V_0_tready           (1'b1),
        .Rsi_BufferWriter_Config_V_0_tready               (1'b1),
        .Rsi_BufferWriter_Param_V_0_tready                (1'b1),
        .Sam_CircularBuffer_Config_V_0_tready             (1'b1),
        .Sifpga_CircularBuffer_Config_V_0_tready          (1'b1),
        .Sifpga_MsgParserError_Flag_V_0_tready            (1'b1),
        .Sifpga_MsgSender_Flag_V_0_tready                 (1'b1),
        .SoftResetReq_Flag_V_0_tready                     (1'b1),
        .ZynqPs_WriteMessage_V_0_tready                   (1'b1)
        // not: wrapper'daki diger cikislar (debug_param_*, HuzmeId_0, ...) acik birakildi
    );

    initial begin clk = 1'b0; forever #2 clk = ~clk; end

    initial begin
        mbx = new();
        drv = new(s_axis_if, mbx);
        gen = new(mbx, "input_data.txt");

        rst_n = 1'b0;
        fork drv.reset(); join_none   // reset kalkisini bekler
        #100 rst_n = 1'b1;
        #10;
        fork drv.run(); join_none
        gen.run();

        #5000;
        $display("[TB_TOP] Simulasyon sonlandi.");
        $finish;
    end
endmodule
