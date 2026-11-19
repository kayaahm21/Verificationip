`timescale 1ns / 1ps

// =====================================================================
// tb_rsi_check (v1.0.7): RSI modellerinin (sim_model_rsi x3) kendi kendini kontrol eden testi
//
// SIFPGA'yi TAKLIT EDER: her tur icin once 1DEA0003 mesajini cpu_pkg::track_cfg_msgs'a verir (gercekte CPU VIP surucusu yapar), sonra her
// RSI'nin s_axis_rq portuna ICD'deki "SHOB HUZME VERISI & SCIT" mesajini (ID 2, LEN, 88 B header, kanal basina N I + N Q float32,
// GAC SCIT, SHOB SCIT, SIBFPGA SCIT, FOOTER) MemWr olarak yazar ve MSI1 verir.
//
//   Tur 1: M=6, darbe=2, ornek=4 (N=8), n_k = 2/2/2, birlestirme = toplam (carpan 3)                      -> hepsi DOGRU
//   Tur 2: M=4, darbe=1, ornek=4 (N=4), n_k = 2/1/1 (offset'ler farkli)                                    -> hepsi DOGRU
//   Tur 3: hata turu: RSI1 carpan 1 (yalniz SHOB-1, uyari), RSI2 yanlis baslangic adresi, RSI3 eksik kelime
//          -> RSI1 DOGRU (kural uyarisi), RSI2 YANLIS, RSI3 YANLIS (LEN uyusmuyor)
//   Tur 4: RSI1 MSI2 ("yazilamadi") ile kapanir -> basarili=0 raporlanir
//   Tur 5: FOOTER bozuk -> YANLIS
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

    // Turun SHOB->RSI mesaj parametreleri (cfg_huzpar doldurur; write_data header'a yazar)
    bit [31:0] tb_hid = 0;
    int        tb_m = 0, tb_darbe = 0, tb_ornek = 0;

    // SIBFPGA -> RSI mesajini 'start' adresinden itibaren, 128 baytlik TLP'lerle yazar.
    //   beams: bu RSI'nin kanallari (global huzme sirasi); nsamp = N; mul: desen carpani;
    //   skip_last: son Q kelimesini yazma (eksik kelime); bad_footer: FOOTER'in son kelimesini boz
    task automatic write_data(int k, bit [63:0] start, int beams[$], int nsamp, int mul, bit skip_last, bit bad_footer = 1'b0);
        bit [7:0]  pl[$];
        bit [7:0]  msg[$];
        bit [63:0] a;
        bit [31:0] w;
        int        len;
        pl.delete(); msg.delete();
        len = 88 + beams.size() * nsamp * 8 + 1920 + 32 + 16 + 16;
        push32(msg, 32'h00000002);                 // ID
        push32(msg, 32'(len));                     // LEN (yalniz veri)
        push32(msg, tb_hid);                       // header 0: huzme ID
        push16(msg, 16'd1); push16(msg, 16'(tb_m));        // 4: durum (HO), 6: alma huzme sayisi
        push32(msg, 32'(tb_darbe)); push32(msg, 32'(tb_ornek));   // 8, 12
        push64(msg, 64'd0);                        // 16: reserved
        for (int g = 0; g < 8; g++) push32(msg, (g < 4) ? 32'h3FFFFFFF : 32'h0);   // 24..52: GAC maskeleri
        msg.push_back(8'h01); msg.push_back(8'h01);        // 56, 57: kart kullanim durumlari
        for (int r = 0; r < 30; r++) msg.push_back(8'h00); // 58..87: reserved
        foreach (beams[bi]) begin
            for (int n = 0; n < nsamp; n++) begin w = fl(mul * code_of(beams[bi], n));     push32(msg, w); end   // I blogu
            for (int n = 0; n < nsamp; n++) begin w = fl(-(mul * code_of(beams[bi], n))); push32(msg, w); end   // Q blogu
        end
        for (int r = 0; r < 1920 + 32 + 16; r++) msg.push_back(8'h00);   // GAC SCIT, SHOB SCIT, SIBFPGA SCIT
        push32(msg, 32'hAAAAAAAA); push32(msg, 32'hBBBBBBBB); push32(msg, 32'hCCCCCCCC);
        push32(msg, bad_footer ? 32'hDEADBEEF : 32'hDDDDDDDD);
        if (skip_last) begin                        // son Q kelimesini kuyruktan once cikar: tum kuyruk bir kelime one kayar
            int q_end = 8 + 88 + beams.size() * nsamp * 8;
            for (int r = 0; r < 4; r++) msg.delete(q_end - 4);
        end
        a = start;
        foreach (msg[i]) begin
            pl.push_back(msg[i]);
            if (pl.size() == 128) begin send_rq(k, a, pl); a += 128; pl.delete(); end
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
        tb_hid = hid; tb_m = m; tb_darbe = darbe; tb_ornek = ornek;
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
            begin write_data(1, SA1 + 64'h100, b1, 8, 3, 1'b0); msi(1, 0); end
            begin write_data(2, SA2 + 64'h200, b2, 8, 3, 1'b0); msi(2, 0); end
            begin write_data(3, SA3 + 64'h300, b3, 8, 3, 1'b0); msi(3, 0); end
        join
        repeat (100) @(posedge uclk[1]);
        chk(r_printed[0], "R1 tur 1: uc RSI raporladi");
        chk(r_dogru[1][0] && r_dogru[2][0] && r_dogru[3][0], "R1 tur 1: uc RSI DOGRU");
        chk(r_basarili[1][0] && r_basarili[2][0] && r_basarili[3][0], "R1 tur 1: MSI1 (yazildi) ile kapandi");
        chk(count_in("rsi_out_rsi1.txt", "BIRLESTIRME KURALI: TOPLAM (SHOB-1 + SHOB-2) (carpan=3)") >= 1, "R1 RSI1 kurali: toplam (carpan 3)");
        chk(count_in("rsi_out_rsi1.txt", "MESAJ: ID=00000002 LEN=2200") >= 1, "R1 RSI1 mesaj: ID=2, LEN=2200 (2072 + 8 * K=2 * N=8)");
        chk(count_in("rsi_out_rsi1.txt", "HEADER: huzme_id=0000a001 durum=1 (HO) alma_huzme=6 darbe=2 ornek=4 (N=8)") >= 1, "R1 RSI1 header alanlari");
        chk(count_in("rsi_out_rsi1.txt", "KANAL SAYISI K=2") >= 1, "R1 RSI1 kanal sayisi 2");
        chk(count_in("rsi_out_rsi1.txt", "FOOTER: aaaaaaaa bbbbbbbb cccccccc dddddddd -> OK") >= 1, "R1 RSI1 FOOTER OK");
        chk(count_in("rsi_out_rsi1.txt", "HAM DOKUM") >= 1, "R1 RSI1 ham dokum yazildi");
        chk(count_in("rsi_out_rsi2.txt", "ADRES OK") >= 1, "R1 RSI2 adres = baslangic + offset");
        chk(count_in("rsi_tur_ozeti.txt", "birlesim: 6 huzme bekleniyor, eksik=0, birden cok RSI'de=0") >= 1, "R1 birlesim: 6 huzme eksiksiz, cakisma yok");

        // ---------------- Tur 2 ----------------
        cfg_huzpar(64'h1000, 64'h2000, 64'h3000, 32'h0000A002, 4, 1, 4, 2, 1, 1);
        b1 = '{0, 1}; b2 = '{2}; b3 = '{3};
        fork
            begin write_data(1, SA1 + 64'h1000, b1, 4, 3, 1'b0); msi(1, 0); end
            begin write_data(2, SA2 + 64'h2000, b2, 4, 3, 1'b0); msi(2, 0); end
            begin write_data(3, SA3 + 64'h3000, b3, 4, 3, 1'b0); msi(3, 0); end
        join
        repeat (100) @(posedge uclk[1]);
        chk(r_printed[1], "R2 tur 2: uc RSI raporladi");
        chk(r_dogru[1][1] && r_dogru[2][1] && r_dogru[3][1], "R2 tur 2: uc RSI DOGRU (RSI basina 2/1/1 huzme)");
        chk(count_in("rsi_out_rsi3.txt", "KANAL SAYISI K=1") >= 1, "R2 RSI3 kanal sayisi 1");
        chk(count_in("rsi_tur_ozeti.txt", "birlesim: 4 huzme bekleniyor, eksik=0, birden cok RSI'de=0") >= 1, "R2 birlesim: 4 huzme eksiksiz");

        // ---------------- Tur 3 (hatalar) ----------------
        cfg_huzpar(64'h40, 64'h80, 64'hC0, 32'h0000A003, 6, 1, 4, 2, 2, 2);
        b1 = '{0, 1}; b2 = '{2, 3}; b3 = '{4, 5};
        fork
            begin write_data(1, SA1 + 64'h40, b1, 4, 1, 1'b0); msi(1, 0); end      // carpan 1: uyari, hata degil
            begin write_data(2, SA2 + 64'h84, b2, 4, 3, 1'b0); msi(2, 0); end      // yanlis baslangic (+4)
            begin write_data(3, SA3 + 64'hC0, b3, 4, 3, 1'b1); msi(3, 0); end      // son ornek eksik
        join
        repeat (100) @(posedge uclk[1]);
        chk(r_reported[1][2] && r_dogru[1][2], "R3 RSI1 (yalniz SHOB-1 kurali) DOGRU sayildi");
        chk(r_reported[2][2] && !r_dogru[2][2], "R3 RSI2 yanlis baslangic adresi YAKALANDI");
        chk(r_reported[3][2] && !r_dogru[3][2], "R3 RSI3 eksik ornek YAKALANDI");
        chk(count_in("rsi_out_rsi1.txt", "BIRLESTIRME KURALI: yalniz SHOB-1 (carpan=1)") >= 1, "R3 RSI1 kural: yalniz SHOB-1");
        chk(count_in("rsi_out_rsi2.txt", "ADRES HATA") >= 1, "R3 RSI2 ADRES HATA satiri");
        chk(count_in("rsi_out_rsi3.txt", "HATA LEN uyusmuyor") >= 1, "R3 RSI3 eksik kelime: LEN uyusmuyor satiri");
        chk(count_in("rsi_tur_ozeti.txt", "BASARISIZ ya da YANLIS") >= 1, "R3 tur ozeti BASARISIZ/YANLIS");
        chk(count_in("rsi_out_rsi3.txt", "TESHIS: gelen bayt - (8+LEN) = ") >= 1, "R3 RSI3 LEN farki tanilamasi yazildi");
        chk(r_lendiff[3][2] != 0 && r_lendiff[1][2] == 0, "R3 LEN farki yalniz RSI3'te kaydedildi");
        chk(count_in("rsi_tur_ozeti.txt", "LENFARK=") >= 1, "R3 ozet satirinda LENFARK");

        // ---------------- Tur 4: MSI2 (yazilamadi) ----------------
        cfg_huzpar(64'h0, 64'h0, 64'h0, 32'h0000A004, 4, 1, 4, 2, 1, 1);
        b1 = '{0, 1}; b2 = '{2}; b3 = '{3};
        fork
            begin write_data(1, SA1, b1, 4, 3, 1'b0); msi(1, 1); end    // MSI2
            begin write_data(2, SA2, b2, 4, 3, 1'b0); msi(2, 0); end
            begin write_data(3, SA3, b3, 4, 3, 1'b0); msi(3, 0); end
        join
        repeat (100) @(posedge uclk[1]);
        chk(r_reported[1][3] && !r_basarili[1][3] && r_basarili[2][3], "R4 RSI1 MSI2 ile (yazilamadi), RSI2 MSI1 ile kapandi");
        chk(count_in("rsi_out_rsi1.txt", "(MSI2: YAZILAMADI)") >= 1, "R4 RSI1 dosyasinda MSI2 turu");

        // ---------------- Tur 5: FOOTER bozuk ----------------
        cfg_huzpar(64'h0, 64'h0, 64'h0, 32'h0000A005, 4, 1, 4, 2, 1, 1);
        b1 = '{0, 1}; b2 = '{2}; b3 = '{3};
        fork
            begin write_data(1, SA1, b1, 4, 3, 1'b0, 1'b1); msi(1, 0); end     // FOOTER bozuk
            begin write_data(2, SA2, b2, 4, 3, 1'b0); msi(2, 0); end
            begin write_data(3, SA3, b3, 4, 3, 1'b0); msi(3, 0); end
        join
        repeat (100) @(posedge uclk[1]);
        chk(r_reported[1][4] && !r_dogru[1][4], "R5 RSI1 bozuk FOOTER YAKALANDI");
        chk(count_in("rsi_out_rsi1.txt", "FOOTER: aaaaaaaa bbbbbbbb cccccccc deadbeef -> HATA") >= 1, "R5 RSI1 FOOTER HATA satiri");
        chk(r_dogru[2][4] && r_dogru[3][4], "R5 RSI2 ve RSI3 DOGRU");

        // ---------------- Tur 6/7: tur 6 reddedildi (SIFPGA veri yazmadi, MSI yok); tur 7 normal ----------------
        // v1.0.9: eslesme huzme ID'ye gore olmali; tur 7 DOGRU sayilmali, tur 6 "VERI GELMEDI" olmali.
        cfg_huzpar(64'h0, 64'h0, 64'h0, 32'h0000A006, 4, 1, 4, 2, 1, 1);
        cfg_huzpar(64'h0, 64'h0, 64'h0, 32'h0000A007, 4, 1, 4, 2, 1, 1);
        b1 = '{0, 1}; b2 = '{2}; b3 = '{3};
        fork
            begin msi(1, 2); repeat (60) @(posedge uclk[1]); write_data(1, SA1, b1, 4, 3, 1'b0); msi(1, 0); end   // once MSI3
            begin write_data(2, SA2, b2, 4, 3, 1'b0); msi(2, 0); end
            begin write_data(3, SA3, b3, 4, 3, 1'b0); msi(3, 0); end
        join
        repeat (100) @(posedge uclk[1]);
        chk(r_msi3[1][6] == 1 && r_msi3[2][6] == 0, "R7 RSI1 tur 7 oncesi MSI3=1 sayildi, RSI2'de yok");
        chk(count_in("rsi_tur_ozeti.txt", "TUR 7 huzme_id=0000a007") >= 1 && count_in("rsi_tur_ozeti.txt", " MSI3=1") >= 1, "R7 ozet satirinda MSI3=1");
        chk(count_in("rsi_out_rsi1.txt", "TESHIS: bu turdan once SIFPGA 1 kez MSI3") >= 1, "R7 RSI1 dosyasinda MSI3 tanilamasi");
        chk(r_missing[1][5] && r_missing[2][5] && r_missing[3][5], "R6 tur 6 (veri yok): uc RSI'de VERI GELMEDI");
        chk(r_printed[5], "R6 tur 6 ozete yazildi");
        chk(r_reported[1][6] && !r_missing[1][6] && r_dogru[1][6] && r_dogru[2][6] && r_dogru[3][6],
            "R7 tur 7: huzme ID ile dogru tura eslendi ve DOGRU (tur 6'nin yoklugu kaydirmadi)");
        chk(count_in("rsi_tur_ozeti.txt", "TUR 6 huzme_id=0000a006 M=4 N=4 | RSI1: VERI GELMEDI | RSI2: VERI GELMEDI | RSI3: VERI GELMEDI") >= 1,
            "R6 ozet satiri: VERI GELMEDI");
        chk(count_in("rsi_tur_ozeti.txt", "TUR 7 huzme_id=0000a007") >= 1, "R7 ozet satiri tur 7");
        chk(count_in("rsi_out_rsi1.txt", "ESLESME: huzme ID ile tur 7 secildi (sirada beklenen tur 6") >= 1, "R7 RSI1 dosyasinda ESLESME satiri");

        // ---------------- Tur 8: son tur reddedildi; report() kalan turu isaretler ----------------
        cfg_huzpar(64'h0, 64'h0, 64'h0, 32'h0000A008, 4, 1, 4, 2, 1, 1);
        rsi_flush_missing(1); rsi_flush_missing(2); rsi_flush_missing(3);
        chk(r_missing[1][7] && r_missing[2][7] && r_missing[3][7] && r_printed[7], "R8 en sondaki veri gelmeyen tur flush ile VERI GELMEDI");

        if (errors == 0) $display("[TB] *** TUM TESTLER GECTI ***");
        else             $display("[TB] *** %0d HATA ***", errors);
        $finish;
    end
endmodule
