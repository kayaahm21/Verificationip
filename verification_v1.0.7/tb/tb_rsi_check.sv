`timescale 1ns / 1ps

// =====================================================================
// tb_rsi_check (v1.0.7): RSI modellerinin (sim_model_rsi x3) kendi kendini kontrol eden testi
//
// SIFPGA'yi TAKLIT EDER: her tur icin once 1DEA0001/1DEA0003 mesajlarini cpu_pkg::track_cfg_msgs'a verir
// (gercekte CPU VIP surucusu yapar), sonra her RSI'nin s_axis_rq portuna huzme verisini (float32 I/Q) MemWr
// olarak yazar ve MSI1 verir.
//
//   Tur 1: M=6, darbe=2, ornek=4 (N=8), n_k = 2/2/2, huzme-ana yerlesim, birlestirme = toplam (carpan 3)  -> hepsi DOGRU
//   Tur 2: M=4, darbe=1, ornek=4 (N=4), n_k = 2/1/1, RSI1 ornek-ana yerlesim (offset'ler farkli)           -> hepsi DOGRU
//   Tur 3: hata turu: RSI1 carpan 1 (yalniz SHOB-1, uyari), RSI2 yanlis baslangic adresi, RSI3 eksik ornek
//          -> RSI1 DOGRU (kural uyarisi), RSI2 YANLIS, RSI3 YANLIS
//   Tur 4: RSI1 MSI2 ("yazilamadi") ile kapanir -> basarili=0 raporlanir
// =====================================================================
module tb_rsi_check;
    import cpu_pkg::*;
    import rsi_pkg::*;

    logic         sys_clk = 1'b0;
    logic         uclk       [1:3];
    logic         ureset     [1:3];
    logic [255:0] rq_tdata   [1:3];
    logic [7:0]   rq_tkeep   [1:3];
    logic         rq_tlast   [1:3];
    logic [61:0]  rq_tuser   [1:3];
    logic         rq_tvalid  [1:3];
    logic [3:0]   rq_tready  [1:3];
    logic [31:0]  msi_int    [1:3];

    initial begin
        for (int k = 1; k <= 3; k++) begin
            rq_tdata[k] = '0; rq_tkeep[k] = '0; rq_tlast[k] = 1'b0; rq_tuser[k] = '0;
            rq_tvalid[k] = 1'b0; msi_int[k] = '0;
        end
    end

    genvar g;
    generate
        for (g = 1; g <= 3; g++) begin : u
            logic [255:0] cq_tdata; logic [7:0] cq_tkeep; logic cq_tlast, cq_tvalid; logic [87:0] cq_tuser;
            logic msi_sent, msi_fail, hb_gen;
            sim_model_rsi #(.RSI_ID(g), .OUT_PREFIX("rsi_out")) m (
                .sys_clk(sys_clk), .user_clk(uclk[g]), .user_reset(ureset[g]),
                .m_axis_cq_tdata(cq_tdata), .m_axis_cq_tkeep(cq_tkeep), .m_axis_cq_tlast(cq_tlast),
                .m_axis_cq_tready(1'b1), .m_axis_cq_tuser(cq_tuser), .m_axis_cq_tvalid(cq_tvalid),
                .s_axis_rq_tdata(rq_tdata[g]), .s_axis_rq_tkeep(rq_tkeep[g]), .s_axis_rq_tlast(rq_tlast[g]),
                .s_axis_rq_tready(rq_tready[g]), .s_axis_rq_tuser(rq_tuser[g]), .s_axis_rq_tvalid(rq_tvalid[g]),
                .cfg_interrupt_msi_int(msi_int[g]), .cfg_interrupt_msi_sent(msi_sent), .cfg_interrupt_msi_fail(msi_fail),
                .huzme_basi_obs(1'b0), .huzme_basi_gen(hb_gen)
            );
        end
    endgenerate

    int errors = 0;
    task automatic chk(bit cond, string msg);
        if (!cond) begin $display("[TB] HATA: %s", msg); errors++; end
        else       $display("[TB] tamam: %s", msg);
    endtask

    // ---- int -> float32 (|v| < 2^24 icin tam) ----
    function automatic bit [31:0] fl(int v);
        bit [31:0] mag, r;
        int        e;
        if (v == 0) return 32'd0;
        mag = (v < 0) ? 32'(-v) : 32'(v);
        e = 31;
        while (!mag[e]) e--;
        // mantis: mag'in en anlamli biti disindaki bitler 23 bite hizalanir
        if (e <= 23) r = (mag << (23 - e)) & 32'h007FFFFF;
        else         r = (mag >> (e - 23)) & 32'h007FFFFF;
        return {(v < 0) ? 1'b1 : 1'b0, 8'(127 + e), r[22:0]};
    endfunction

    function automatic int code_of(int m, int n);
        return ((m + 1) << 15) | (n & 32'h7FFF);
    endfunction

    // ---- RQ: bir MemWr TLP'si (payload DWORD'un kati) ----
    task automatic send_rq(int k, bit [63:0] addr, bit [7:0] payload[$]);
        bit [7:0]   pkt[$];
        int         dw = payload.size() / 4;
        bit [31:0]  dw0, dw1, dw2, dw3;
        int         off, n;
        bit [255:0] word;
        bit [7:0]   keep;
        bit         first;
        pkt.delete();
        dw0 = {addr[31:2], 2'b00};
        dw1 = addr[63:32];
        dw2 = {16'h0000, 1'b0, REQ_TYPE_MEMWR, 11'(dw)};
        dw3 = 32'h0;
        for (int i = 0; i < 4; i++) pkt.push_back(dw0[8*i +: 8]);
        for (int i = 0; i < 4; i++) pkt.push_back(dw1[8*i +: 8]);
        for (int i = 0; i < 4; i++) pkt.push_back(dw2[8*i +: 8]);
        for (int i = 0; i < 4; i++) pkt.push_back(dw3[8*i +: 8]);
        foreach (payload[i]) pkt.push_back(payload[i]);
        off = 0; first = 1'b1;
        @(posedge uclk[k]);
        while (off < pkt.size()) begin
            n = ((pkt.size() - off) < 32) ? (pkt.size() - off) : 32;
            word = '0; keep = '0;
            for (int b = 0; b < n; b++) begin
                word[8*b +: 8] = pkt[off + b];
                keep[b / 4]    = 1'b1;
            end
            rq_tvalid[k] <= 1'b1;
            rq_tdata[k]  <= word;
            rq_tkeep[k]  <= keep;
            rq_tlast[k]  <= (off + n >= pkt.size());
            rq_tuser[k]  <= first ? {54'b0, ((dw > 1) ? 4'hF : 4'h0), 4'hF} : 62'b0;
            @(posedge uclk[k]);
            if (rq_tready[k][0]) begin off += n; first = 1'b0; end
        end
        rq_tvalid[k] <= 1'b0;
        rq_tlast[k]  <= 1'b0;
    endtask

    // Verilen huzmeleri (sirayla) 'start' adresinden itibaren, 128 baytlik TLP'lerle yazar.
    //   layout 0: huzme-ana (m -> n -> I,Q), 1: ornek-ana (n -> m -> I,Q); mul: desen carpani; skip_last: son ornegi yazma
    task automatic write_data(int k, bit [63:0] start, int beams[$], int nsamp, int layout, int mul, bit skip_last);
        bit [7:0]  pl[$];
        bit [63:0] a;
        bit [31:0] i_w, q_w;
        int        total, cnt;
        a = start; cnt = 0;
        pl.delete();
        total = beams.size() * nsamp;
        if (layout == 0) begin
            foreach (beams[bi])
                for (int n = 0; n < nsamp; n++) begin
                    cnt++;
                    if (skip_last && cnt == total) continue;
                    i_w = fl(mul * code_of(beams[bi], n));
                    q_w = fl(-(mul * code_of(beams[bi], n)));
                    for (int b = 0; b < 4; b++) pl.push_back(i_w[8*b +: 8]);
                    for (int b = 0; b < 4; b++) pl.push_back(q_w[8*b +: 8]);
                    if (pl.size() == 128) begin send_rq(k, a, pl); a += 128; pl.delete(); end
                end
        end else begin
            for (int n = 0; n < nsamp; n++)
                foreach (beams[bi]) begin
                    cnt++;
                    if (skip_last && cnt == total) continue;
                    i_w = fl(mul * code_of(beams[bi], n));
                    q_w = fl(-(mul * code_of(beams[bi], n)));
                    for (int b = 0; b < 4; b++) pl.push_back(i_w[8*b +: 8]);
                    for (int b = 0; b < 4; b++) pl.push_back(q_w[8*b +: 8]);
                    if (pl.size() == 128) begin send_rq(k, a, pl); a += 128; pl.delete(); end
                end
        end
        if (pl.size() != 0) send_rq(k, a, pl);
    endtask

    task automatic msi(int k, int bitno);
        @(posedge uclk[k]);
        msi_int[k][bitno] <= 1'b1;
        repeat (4) @(posedge uclk[k]);
        msi_int[k][bitno] <= 1'b0;
        repeat (50) @(posedge uclk[k]);
    endtask

    // ---- SIFPGA yapilandirma mesajlarini (CPU VIP surucusunun yerine) paylasilan duruma verir ----
    task automatic push32(ref bit [7:0] q[$], input bit [31:0] v);
        for (int i = 0; i < 4; i++) q.push_back(v[8*i +: 8]);
    endtask
    task automatic push64(ref bit [7:0] q[$], input bit [63:0] v);
        for (int i = 0; i < 8; i++) q.push_back(v[8*i +: 8]);
    endtask
    task automatic push16(ref bit [7:0] q[$], input bit [15:0] v);
        for (int i = 0; i < 2; i++) q.push_back(v[8*i +: 8]);
    endtask

    task automatic cfg_adres(bit [63:0] a1, bit [63:0] a2, bit [63:0] a3);
        bit [7:0] q[$];
        bit [7:0] pkt[];
        q.delete();
        for (int i = 0; i < 16; i++) q.push_back(8'h00);      // 16 B descriptor
        push32(q, 32'h1DEA0001); push32(q, 32'd124);
        for (int i = 0; i < 96; i++) q.push_back(8'h00);      // 4 buffer konfigurasyonu (0..95)
        push64(q, a1); push64(q, a2); push64(q, a3);          // 96..119
        q.push_back(8'd3); q.push_back(8'h10); q.push_back(8'h00); q.push_back(8'h00);   // 120..123
        pkt = new[q.size()];
        foreach (q[i]) pkt[i] = q[i];
        track_cfg_msgs(pkt, 1'b0);
    endtask

    task automatic cfg_huzpar(bit [63:0] o1, bit [63:0] o2, bit [63:0] o3, bit [31:0] hid, int m, int darbe, int ornek,
                              int n1, int n2, int n3);
        bit [7:0] q[$];
        bit [7:0] pkt[];
        q.delete();
        for (int i = 0; i < 16; i++) q.push_back(8'h00);
        push32(q, 32'h1DEA0003); push32(q, 32'd56);
        push64(q, o1); push64(q, o2); push64(q, o3);          // 0, 8, 16
        push32(q, hid);                                       // 24
        push16(q, 16'(m)); push16(q, 16'(darbe)); push16(q, 16'(ornek));   // 28, 30, 32
        q.push_back(8'h03); q.push_back(8'h00);               // 34 SHOB kullanimi, 35 mod
        q.push_back(8'(n1)); q.push_back(8'(n2)); q.push_back(8'(n3));     // 36..38
        for (int i = 0; i < 17; i++) q.push_back(8'h00);      // 39..55
        pkt = new[q.size()];
        foreach (q[i]) pkt[i] = q[i];
        track_cfg_msgs(pkt, 1'b0);
    endtask

    function automatic int count_in(string fname, string pat);
        int    fd, cnt;
        string line;
        cnt = 0;
        fd = $fopen(fname, "r");
        while (fd != 0 && !$feof(fd)) begin
            line = "";
            if ($fgets(line, fd) == 0) break;
            for (int i = 0; i + pat.len() <= line.len(); i++)
                if (line.substr(i, i + pat.len() - 1) == pat) begin cnt++; break; end
        end
        if (fd != 0) $fclose(fd);
        return cnt;
    endfunction

    localparam bit [63:0] SA1 = 64'h0000_0001_0000_0000;
    localparam bit [63:0] SA2 = 64'h0000_0002_0000_0000;
    localparam bit [63:0] SA3 = 64'h0000_0003_0000_0000;

    int b1[$], b2[$], b3[$];

    initial begin
        $timeformat(-9, 0, " ns", 0);
        repeat (40) @(posedge uclk[1]);

        // ---------------- Tur 1 ----------------
        cfg_adres(SA1, SA2, SA3);
        chk(rsi_start_valid && rsi_start_addr[1] == SA1 && rsi_start_addr[2] == SA2 && rsi_start_addr[3] == SA3,
            "R0 1DEA0001'den RSI baslangic adresleri okundu");
        cfg_huzpar(64'h100, 64'h200, 64'h300, 32'h0000A001, 6, 2, 4, 2, 2, 2);
        chk(t_count == 1 && t_m[0] == 6 && t_nsample[0] == 8 && t_nk[1][0] == 2 && t_off[2][0] == 64'h200,
            "R0 1DEA0003 cozuldu (M=6, N=darbe*ornek=8, n_k, offset)");
        b1 = '{0, 1}; b2 = '{2, 3}; b3 = '{4, 5};
        fork
            begin write_data(1, SA1 + 64'h100, b1, 8, 0, 3, 1'b0); msi(1, 0); end
            begin write_data(2, SA2 + 64'h200, b2, 8, 0, 3, 1'b0); msi(2, 0); end
            begin write_data(3, SA3 + 64'h300, b3, 8, 0, 3, 1'b0); msi(3, 0); end
        join
        repeat (100) @(posedge uclk[1]);
        chk(r_printed[0], "R1 tur 1: uc RSI raporladi");
        chk(r_dogru[1][0] && r_dogru[2][0] && r_dogru[3][0], "R1 tur 1: uc RSI DOGRU");
        chk(r_basarili[1][0] && r_basarili[2][0] && r_basarili[3][0], "R1 tur 1: MSI1 (yazildi) ile kapandi");
        chk(count_in("rsi_out_rsi1.txt", "BIRLESTIRME KURALI: TOPLAM (SHOB-1 + SHOB-2) (carpan=3)") >= 1, "R1 RSI1 kurali: toplam (carpan 3)");
        chk(count_in("rsi_out_rsi1.txt", "YERLESIM: HUZME-ANA") >= 1, "R1 RSI1 yerlesim: huzme-ana");
        chk(count_in("rsi_out_rsi2.txt", "ADRES OK") >= 1, "R1 RSI2 adres = baslangic + offset");
        chk(count_in("rsi_tur_ozeti.txt", "birlesim: 6 huzme bekleniyor, eksik=0, birden cok RSI'de=0") >= 1, "R1 birlesim: 6 huzme eksiksiz, cakisma yok");

        // ---------------- Tur 2 ----------------
        cfg_huzpar(64'h1000, 64'h2000, 64'h3000, 32'h0000A002, 4, 1, 4, 2, 1, 1);
        b1 = '{0, 1}; b2 = '{2}; b3 = '{3};
        fork
            begin write_data(1, SA1 + 64'h1000, b1, 4, 1, 3, 1'b0); msi(1, 0); end
            begin write_data(2, SA2 + 64'h2000, b2, 4, 0, 3, 1'b0); msi(2, 0); end
            begin write_data(3, SA3 + 64'h3000, b3, 4, 0, 3, 1'b0); msi(3, 0); end
        join
        repeat (100) @(posedge uclk[1]);
        chk(r_printed[1], "R2 tur 2: uc RSI raporladi");
        chk(r_dogru[1][1] && r_dogru[2][1] && r_dogru[3][1], "R2 tur 2: uc RSI DOGRU (RSI basina 2/1/1 huzme)");
        chk(count_in("rsi_out_rsi1.txt", "YERLESIM: ORNEK-ANA") >= 1, "R2 RSI1 yerlesim: ornek-ana saptandi");
        chk(count_in("rsi_tur_ozeti.txt", "birlesim: 4 huzme bekleniyor, eksik=0, birden cok RSI'de=0") >= 1, "R2 birlesim: 4 huzme eksiksiz");

        // ---------------- Tur 3 (hatalar) ----------------
        cfg_huzpar(64'h40, 64'h80, 64'hC0, 32'h0000A003, 6, 1, 4, 2, 2, 2);
        b1 = '{0, 1}; b2 = '{2, 3}; b3 = '{4, 5};
        fork
            begin write_data(1, SA1 + 64'h40, b1, 4, 0, 1, 1'b0); msi(1, 0); end      // carpan 1: uyari, hata degil
            begin write_data(2, SA2 + 64'h84, b2, 4, 0, 3, 1'b0); msi(2, 0); end      // yanlis baslangic (+4)
            begin write_data(3, SA3 + 64'hC0, b3, 4, 0, 3, 1'b1); msi(3, 0); end      // son ornek eksik
        join
        repeat (100) @(posedge uclk[1]);
        chk(r_reported[1][2] && r_dogru[1][2], "R3 RSI1 (yalniz SHOB-1 kurali) DOGRU sayildi");
        chk(r_reported[2][2] && !r_dogru[2][2], "R3 RSI2 yanlis baslangic adresi YAKALANDI");
        chk(r_reported[3][2] && !r_dogru[3][2], "R3 RSI3 eksik ornek YAKALANDI");
        chk(count_in("rsi_out_rsi1.txt", "BIRLESTIRME KURALI: yalniz SHOB-1 (carpan=1)") >= 1, "R3 RSI1 kural: yalniz SHOB-1");
        chk(count_in("rsi_out_rsi2.txt", "ADRES HATA") >= 1, "R3 RSI2 ADRES HATA satiri");
        chk(count_in("rsi_out_rsi3.txt", "HATA huzme 5: 3 ornek var, beklenen N=4") >= 1, "R3 RSI3 eksik ornek satiri");
        chk(count_in("rsi_tur_ozeti.txt", "BASARISIZ ya da YANLIS") >= 1, "R3 tur ozeti BASARISIZ/YANLIS");

        // ---------------- Tur 4: MSI2 (yazilamadi) ----------------
        cfg_huzpar(64'h0, 64'h0, 64'h0, 32'h0000A004, 4, 1, 4, 2, 1, 1);
        b1 = '{0, 1}; b2 = '{2}; b3 = '{3};
        fork
            begin write_data(1, SA1, b1, 4, 0, 3, 1'b0); msi(1, 1); end    // MSI2
            begin write_data(2, SA2, b2, 4, 0, 3, 1'b0); msi(2, 0); end
            begin write_data(3, SA3, b3, 4, 0, 3, 1'b0); msi(3, 0); end
        join
        repeat (100) @(posedge uclk[1]);
        chk(r_reported[1][3] && !r_basarili[1][3] && r_basarili[2][3], "R4 RSI1 MSI2 ile (yazilamadi), RSI2 MSI1 ile kapandi");
        chk(count_in("rsi_out_rsi1.txt", "(MSI2: YAZILAMADI)") >= 1, "R4 RSI1 dosyasinda MSI2 turu");

        if (errors == 0) $display("[TB] *** TUM TESTLER GECTI ***");
        else             $display("[TB] *** %0d HATA ***", errors);
        $finish;
    end
endmodule
