`timescale 1ns / 1ps

// =====================================================================
// axis_tx_if : AXI-Stream arayuzu (VIP -> tasarim yonunde veri akisi)
//
//  - rst_n      : aktif-dusuk reset. 1 = reset kalkti, VIP calismaya baslayabilir.
//  - KEEP_GRAN  : tkeep'in her bitinin kac bayta karsilik geldigi.
//                   1 -> bayt basina tkeep (design_1_wrapper test yolu)
//                   4 -> DWORD basina tkeep (gercek UltraScale+ PCIe IP, 256-bit icin 8 bit)
//  - TUSER_WIDTH: 88 -> UltraScale+ CQ duzeni, daha kucukse basit duzen (bkz. scn_pkg::driver)
// =====================================================================
interface axis_tx_if #(parameter int DATA_WIDTH  = 256,
                       parameter int TUSER_WIDTH = 88,
                       parameter int KEEP_GRAN   = 4)(
    input logic aclk,
    input logic rst_n
);
    localparam int KEEP_WIDTH = DATA_WIDTH / 8 / KEEP_GRAN;

    logic                    tvalid;
    logic                    tready;   // alici (tasarim) tarafindan surulur
    logic [DATA_WIDTH-1:0]   tdata;
    logic [KEEP_WIDTH-1:0]   tkeep;
    logic                    tlast;
    logic [TUSER_WIDTH-1:0]  tuser;
endinterface
