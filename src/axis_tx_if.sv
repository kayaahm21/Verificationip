`timescale 1ns / 1ps

// AXI-Stream arayuzu. rst_n aktif-dusuk reset (1 = reset kalkti).
interface axis_tx_if #(parameter int DATA_WIDTH = 256, parameter int TUSER_WIDTH = 88,
                       parameter int KEEP_GRAN  = 4)(  // 1: bayt basina tkeep, 4: DWORD basina (US+ IP)
    input logic aclk,
    input logic rst_n
);
    localparam int KEEP_WIDTH = DATA_WIDTH / 8 / KEEP_GRAN;

    logic                    tvalid;
    logic                    tready;
    logic [DATA_WIDTH-1:0]   tdata;
    logic [KEEP_WIDTH-1:0]   tkeep;
    logic                    tlast;
    logic [TUSER_WIDTH-1:0]  tuser;
endinterface
