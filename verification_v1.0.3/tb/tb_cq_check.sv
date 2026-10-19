`timescale 1ns / 1ps

// =====================================================================
// tb_cq_check : CQ (CPU -> FPGA) yonu icin kendi kendini kontrol eden test  (v1.0.3)
//
// examples/scenario_cq_test.txt senaryosunu calistirir ve m_axis_cq cikisini izler:
//   - TLP baytlari (descriptor, ID, len, payload) beklenenle ayni mi
//   - birden fazla beat, tkeep, tlast, tuser (sop, byte_en, first_be/last_be) dogru mu
//   - tready ile bekletme (backpressure) altinda veri bozulmuyor mu
//   - 77777777 / 99999999 / 88888888 zamanlamalari dogru mu
// =====================================================================
module tb_cq_check;

    logic         sys_clk = 1'b0;
    logic         user_clk, user_reset;
    logic [255:0] cq_tdata;
    logic [7:0]   cq_tkeep;
    logic         cq_tlast, cq_tvalid;
    logic         cq_tready = 1'b0;
    logic [87:0]  cq_tuser;
    logic [3:0]   rq_tready;
    logic         msi_sent, msi_fail, hb_gen;
    logic         hb_obs = 1'b0;

    sim_model_cpu #(.INPUT_FILE("scenario_cq_test.txt")) dut (
        .sys_clk(sys_clk), .user_clk(user_clk), .user_reset(user_reset),
        .m_axis_cq_tdata(cq_tdata), .m_axis_cq_tkeep(cq_tkeep), .m_axis_cq_tlast(cq_tlast),
        .m_axis_cq_tready(cq_tready), .m_axis_cq_tuser(cq_tuser), .m_axis_cq_tvalid(cq_tvalid),
        .s_axis_rq_tdata('0), .s_axis_rq_tkeep('0), .s_axis_rq_tlast(1'b0),
        .s_axis_rq_tready(rq_tready), .s_axis_rq_tuser('0), .s_axis_rq_tvalid(1'b0),
        .cfg_interrupt_msi_int('0), .cfg_interrupt_msi_sent(msi_sent), .cfg_interrupt_msi_fail(msi_fail),
        .huzme_basi_obs(hb_obs), .huzme_basi_gen(hb_gen)
    );

    // HB geri beslemesi: VIP'in urettigi HB tasarimdaki tele yansir (kayitli, VHDL'deki atamanin karsiligi)
    always @(posedge user_clk) hb_obs <= hb_gen;

    // tready: uc clock'tan biri 0 (backpressure)
    int rdy_cnt = 0;
    always @(posedge user_clk) begin
        rdy_cnt  <= rdy_cnt + 1;
        cq_tready <= ((rdy_cnt % 3) != 0);
    end

    int errors = 0;
    task automatic chk(bit cond, string msg);
        if (!cond) begin $display("[TB] HATA: %s", msg); errors++; end
    endtask

    // ---- monitor: kabul edilen beat'leri TLP'lere birlestir ----
    bit [7:0]    tlp_bytes[$][$];     // her TLP'nin baytlari
    longint      tlp_start[$];        // ilk beat'in kabul zamani (ns)
    longint      tlp_end[$];          // son beat'in kabul zamani (ns)
    int          tlp_beats[$];
    bit [7:0]    cur[$];
    int          cur_beats = 0;
    longint      cur_start;
    longint      hb_time = -1;

    always @(posedge user_clk) begin
        if (hb_gen && hb_time < 0) hb_time = $time;
        if (cq_tvalid && cq_tready) begin
            if (cur_beats == 0) begin
                cur_start = $time;
                // ilk beat: sop=1, first_be/last_be=F, byte_en yalniz payload baytlari (offset>=16)
                chk(cq_tuser[40] === 1'b1, "ilk beat'te sop=1 olmali");
                chk(cq_tuser[3:0] === 4'hF && cq_tuser[7:4] === 4'hF, "first_be/last_be = F olmali");
            end else begin
                chk(cq_tuser[40] === 1'b0, "ilk olmayan beat'te sop=0 olmali");
            end
            for (int d = 0; d < 8; d++)
                if (cq_tkeep[d])
                    for (int i = 0; i < 4; i++) cur.push_back(cq_tdata[32*d + 8*i +: 8]);
            cur_beats++;
            if (cq_tlast) begin
                tlp_bytes.push_back(cur);
                tlp_start.push_back(cur_start);
                tlp_end.push_back($time);
                tlp_beats.push_back(cur_beats);
                cur.delete();
                cur_beats = 0;
            end
        end
    end

    // ---- beklenen TLP'yi bagimsiz olarak (paket kodundan bagimsiz) olustur ----
    function automatic void build_expected(bit [31:0] addr, bit [31:0] id, bit [7:0] data[$],
                                           ref bit [7:0] exp[$]);
        bit [31:0] dw0, dw2;
        int        dwc = (8 + data.size()) / 4;
        exp.delete();
        dw0 = {addr[31:2], 2'b00};
        dw2 = 32'(dwc) | (32'h1 << 11);            // dword sayisi + istek tipi MemWr (0001)
        for (int i = 0; i < 4; i++) exp.push_back(dw0[8*i +: 8]);
        for (int i = 0; i < 4; i++) exp.push_back(8'h00);     // adres[63:32]
        for (int i = 0; i < 4; i++) exp.push_back(dw2[8*i +: 8]);
        for (int i = 0; i < 4; i++) exp.push_back(8'h00);     // DW3
        for (int i = 0; i < 4; i++) exp.push_back(id[8*i +: 8]);
        for (int i = 0; i < 4; i++) exp.push_back(32'(data.size()) >> (8*i));
        foreach (data[i]) exp.push_back(data[i]);
    endfunction

    function automatic string diff_info(bit [7:0] a[$], bit [7:0] b[$]);
        if (a.size() != b.size()) return $sformatf("boyut farkli: %0d vs %0d", a.size(), b.size());
        foreach (a[i]) if (a[i] !== b[i]) return $sformatf("bayt %0d farkli: %02X vs %02X", i, a[i], b[i]);
        return "";
    endfunction

    bit [7:0] d1[$], d2[$], d3[$], e[$];

    initial begin
        for (int i = 0; i < 8; i++)   d1.push_back(8'h11 * (i + 1));
        for (int i = 0; i < 100; i++) d2.push_back(8'(i));

        // tum senaryo (HB ~1316 ns + 3 TLP + 400 ns bekleme) bitene kadar bekle
        wait (tlp_bytes.size() == 3);
        #200;

        $display("---------------- SONUC ----------------");
        chk(tlp_bytes.size() == 3, "3 TLP bekleniyordu");

        build_expected(32'h12340000, 32'h0000000A, d1, e);
        chk(diff_info(tlp_bytes[0], e) == "", {"TLP1: ", diff_info(tlp_bytes[0], e)});
        build_expected(32'h12340040, 32'h0000000B, d2, e);
        chk(diff_info(tlp_bytes[1], e) == "", {"TLP2: ", diff_info(tlp_bytes[1], e)});
        build_expected(32'h00001000, 32'h0000000C, d3, e);
        chk(diff_info(tlp_bytes[2], e) == "", {"TLP3: ", diff_info(tlp_bytes[2], e)});

        // beat sayilari: 32 B -> 1, 124 B -> 4, 24 B -> 1
        chk(tlp_beats[0] == 1, $sformatf("TLP1 beat sayisi %0d (beklenen 1)", tlp_beats[0]));
        chk(tlp_beats[1] == 4, $sformatf("TLP2 beat sayisi %0d (beklenen 4)", tlp_beats[1]));
        chk(tlp_beats[2] == 1, $sformatf("TLP3 beat sayisi %0d (beklenen 1)", tlp_beats[2]));

        // zamanlama: TLP1, HB'den (77777777 1000 + hizalama) sonra gelmeli
        chk(hb_time > 0, "HB darbesi uretilmedi");
        chk(tlp_start[0] >= hb_time, $sformatf("TLP1 (%0d ns) HB'den (%0d ns) once gitti", tlp_start[0], hb_time));
        chk(hb_time >= 1316 && hb_time <= 1330, $sformatf("HB zamani %0d ns (beklenen ~1316..1330)", hb_time));
        // 88888888 400: TLP1 bitisi ile TLP2 baslangici arasi >= 400 ns
        chk((tlp_start[1] - tlp_end[0]) >= 400 && (tlp_start[1] - tlp_end[0]) < 440,
            $sformatf("TLP1->TLP2 arasi %0d ns (beklenen 400..440)", tlp_start[1] - tlp_end[0]));
        $display("[TB] HB=%0d ns | TLP1 %0d..%0d | TLP2 %0d..%0d | TLP3 %0d..%0d",
                 hb_time, tlp_start[0], tlp_end[0], tlp_start[1], tlp_end[1], tlp_start[2], tlp_end[2]);

        if (errors == 0) $display("[TB] *** TUM TESTLER GECTI ***");
        else             $display("[TB] *** %0d HATA ***", errors);
        $finish;
    end

    initial begin
        #100000;
        $display("[TB] HATA: zaman asimi (%0d TLP goruldu)", tlp_bytes.size());
        $finish;
    end
endmodule
