`timescale 1ns / 1ps

// =====================================================================
// tb_scn_rsi_check (v1.0.7): senaryo -> CPU VIP surucusu -> paylasilan RSI durumu zincirinin testi
//
// examples/scenario_huzme_test.txt (tools/gen_huzme_rounds.py ile uretilir) sim_model_cpu ile calistirilir.
// Surucu 1DEA0001 ve 1DEA0003 mesajlarini TLP olarak surerken cpu_pkg::track_cfg_msgs ile RSI baslangic adreslerini
// ve tur bilgilerini (M, N=darbe*ornek, RSI basina huzme sayisi, offset'ler) yakalamali. 1DEA0001 (124 B veri) 33 DWORD
// oldugu icin iki TLP'ye bolunur; yalnizca ilk paket ayristirilir (indeks 96..119 ilk 120 baytin icindedir).
// =====================================================================
module tb_scn_rsi_check;
    import cpu_pkg::*;
    import rsi_pkg::*;

    logic         sys_clk = 1'b0;
    logic         user_clk, user_reset;
    logic [255:0] cq_tdata;
    logic [7:0]   cq_tkeep;
    logic         cq_tlast, cq_tvalid;
    logic [87:0]  cq_tuser;
    logic         msi_sent, msi_fail, hb_gen;
    logic         hb_obs = 1'b0;

    sim_model_cpu #(
        .INPUT_FILE("scenario_huzme_test.txt"),
        .OUT_PREFIX("cpu_out"),
        .TRACE_FILE("rq_trace.txt")
    ) dut (
        .sys_clk(sys_clk), .user_clk(user_clk), .user_reset(user_reset),
        .m_axis_cq_tdata(cq_tdata), .m_axis_cq_tkeep(cq_tkeep), .m_axis_cq_tlast(cq_tlast),
        .m_axis_cq_tready(1'b1), .m_axis_cq_tuser(cq_tuser), .m_axis_cq_tvalid(cq_tvalid),
        .s_axis_rq_tdata(256'd0), .s_axis_rq_tkeep(8'd0), .s_axis_rq_tlast(1'b0),
        .s_axis_rq_tready(), .s_axis_rq_tuser(62'd0), .s_axis_rq_tvalid(1'b0),
        .cfg_interrupt_msi_int(32'd0), .cfg_interrupt_msi_sent(msi_sent), .cfg_interrupt_msi_fail(msi_fail),
        .huzme_basi_obs(hb_obs), .huzme_basi_gen(hb_gen)
    );

    always @(posedge user_clk) hb_obs <= hb_gen;   // tasarimdaki HB teli gibi (bir clock gecikmeli)

    int errors = 0;
    task automatic chk(bit cond, string msg);
        if (!cond) begin $display("[TB] HATA: %s", msg); errors++; end
        else       $display("[TB] tamam: %s", msg);
    endtask

    initial begin
        #150000;   // adres atama + iki tur (HB planlari 20 us)
        chk(rsi_start_valid && rsi_start_addr[1] == 64'h10000000 && rsi_start_addr[2] == 64'h20000000 &&
            rsi_start_addr[3] == 64'h30000000, "G1 1DEA0001: RSI baslangic adresleri (10000000/20000000/30000000)");
        chk(turlar.size() == 2, "G2 iki 1DEA0003 turu yakalandi");
        if (turlar.size() >= 2) begin
            chk(turlar[0].m == 4 && turlar[0].darbe == 1 && turlar[0].ornek == 4 && turlar[0].nsample == 4, "G3 tur 1: M=4, darbe=1, ornek=4, N=4");
            chk(turlar[0].n_k[1] == 2 && turlar[0].n_k[2] == 1 && turlar[0].n_k[3] == 1, "G3 tur 1: RSI basina huzme 2/1/1");
            chk(turlar[0].huzme_id == 32'hA001 && turlar[1].huzme_id == 32'hA002, "G4 huzme ID'leri A001, A002");
            chk(turlar[1].m == 8 && turlar[1].n_k[1] == 3 && turlar[1].n_k[2] == 3 && turlar[1].n_k[3] == 2, "G5 tur 2: M=8, RSI basina huzme 3/3/2");
            chk(turlar[0].offset[1] == 0 && turlar[1].offset[1] == 64'h100 && turlar[1].offset[3] == 64'h100, "G6 offset modu 'step': tur 2'de 0x100");
        end
        if (errors == 0) $display("[TB] *** TUM TESTLER GECTI ***");
        else             $display("[TB] *** %0d HATA ***", errors);
        $finish;
    end
endmodule
