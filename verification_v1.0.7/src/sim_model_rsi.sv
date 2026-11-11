`timescale 1ns / 1ps

// =====================================================================
// sim_model_rsi (v1.0.7) - RSI (radar sinyal isleme) islemci modeli
//
// SIFPGA'nin her RSI'ye PCIe MemWr ile yazdigi huzme verisini alir, MSI1/MSI2 gelince cozer, dogrular,
// txt'ye dokar ve belegi temizler. Portlari sim_model_cpu ile ayni tutuldu (PcieTop'ta SIM_MODE blogu
// icin kolay yerlestirme); CQ tarafi (CPU->FPGA) bostur.
//
// Davranis:
//   * RQ MemWr'lari seyrek (sparse) hafizaya yazar (4 baytlik kelime basina bir kayit). Dairesel degil, pointer yok.
//   * MSI vektoru: bit0 MSI1 (yazildi), bit1 MSI2 (yazilamadi), bit2 MSI3 (SHOB verisi eksik), bit3 MSI4 (SHOB verisi gelmedi).
//     MSI1 ya da MSI2 bir "tur"u kapatir: hafiza cozulur, dogrulanir, dokulur, temizlenir.
//   * Veri float32 I/Q cifti (I sonra Q, 8 bayt/ornek). Dogrulama deseni SHOB VIP'in urettigi kendini tarif eden desendir:
//       kod = ((m+1)<<15) | (n & 0x7FFF), I = +k*kod, Q = -k*kod; birlestirme kurali k otomatik bulunur (3: SHOB-1+SHOB-2 toplami,
//       1 ya da 2: yalniz bir SHOB). Kural cikti dosyasina yazilir.
//   * Kontroller (RSI basina): baslangic adresi = RSI baslangic adresi (1DEA0001) + offset (1DEA0003); tum ornekler gecerli desen;
//     bosluk yok; her huzmede N ornek eksiksiz ve bir kez; huzme sayisi = 1DEA0003'teki RSI'ye indirilecek huzme sayisi.
//     Turun tum RSI'leri raporlayinca cpu_pkg::rsi_report_round birlesim kontrolu (her huzme 0..M-1 bir kez) yapar.
//   * Cikti: <OUT_PREFIX>_rsi<RSI_ID>.txt ve turlarin ozeti rsi_tur_ozeti.txt (rsi_pkg).
//   * Veri yerlesimi (huzme-ana mi, ornek-ana mi) otomatik saptanir ve raporlanir.
// =====================================================================
module sim_model_rsi #(
    parameter int    RSI_ID           = 1,                 // 1..3
    parameter string OUT_PREFIX       = "rsi_out",         // cikti dosyasi on eki (+RSI_OUT=)
    parameter int    CQ_KEEP_WIDTH    = 8,
    parameter int    RQ_KEEP_WIDTH    = 8,
    parameter int    ISR_LATENCY_NS   = 100,               // MSI'dan sonra ISR'nin baslamasi icin bekleme (ns)
    parameter int    MAX_WORDS        = 4194304,           // hafizadaki en cok 4 baytlik kelime; asilirsa uyari verilir ve yazma atilir
    parameter int    DETAIL_LINES     = 64,                // cikti dosyasina yazilan en fazla ornek satiri (0: yok, -1: hepsi)
    parameter int    FP_SCALE_TOL     = 0                  // ayrilmis (float dogrulugu tam olmak zorunda)
)(
    input  logic                     sys_clk,

    output logic                     user_clk,
    output logic                     user_reset,

    output logic [255:0]             m_axis_cq_tdata,
    output logic [CQ_KEEP_WIDTH-1:0] m_axis_cq_tkeep,
    output logic                     m_axis_cq_tlast,
    input  logic                     m_axis_cq_tready,
    output logic [87:0]              m_axis_cq_tuser,
    output logic                     m_axis_cq_tvalid,

    input  logic [255:0]             s_axis_rq_tdata,
    input  logic [RQ_KEEP_WIDTH-1:0] s_axis_rq_tkeep,
    input  logic                     s_axis_rq_tlast,
    output logic [3:0]               s_axis_rq_tready,
    input  logic [61:0]              s_axis_rq_tuser,
    input  logic                     s_axis_rq_tvalid,

    input  logic [31:0]              cfg_interrupt_msi_int,
    output logic                     cfg_interrupt_msi_sent,
    output logic                     cfg_interrupt_msi_fail,

    input  logic                     huzme_basi_obs,
    output logic                     huzme_basi_gen
);
    import cpu_pkg::*;
    import rsi_pkg::*;

    initial begin user_clk = 1'b0; forever #4 user_clk = ~user_clk; end
    initial begin
        user_reset = 1'b1;
        repeat (20) @(posedge user_clk);
        user_reset = 1'b0;
    end

    // CQ bos, HB uretilmez
    assign m_axis_cq_tdata  = '0;
    assign m_axis_cq_tkeep  = '0;
    assign m_axis_cq_tlast  = 1'b0;
    assign m_axis_cq_tuser  = '0;
    assign m_axis_cq_tvalid = 1'b0;
    assign huzme_basi_gen   = 1'b0;
    assign s_axis_rq_tready = 4'hF;
    assign cfg_interrupt_msi_fail = 1'b0;

    // ---------------- RQ yakalama ve hafiza ----------------
    rq_assembler asm;
    rq_pkt       rx_pkt;
    bit          rx_done;

    bit [31:0]   mem [bit [63:0]];          // anahtar: kelime adresi (bayt adresi >> 2)
    int unsigned wr_count = 0;              // bu turda alinan MemWr sayisi
    int unsigned dropped  = 0;
    int unsigned tlp_total = 0;
    int unsigned partial_be_warn = 0;
    int          fd = 0;
    string       out_name;

    // fonksiyon (task degil): xsim, fonksiyonlarin task cagirmasina izin vermez; fonksiyon hem task hem fonksiyondan cagrilabilir
    function automatic void logf(string s);
        if (fd != 0) begin $fdisplay(fd, "%s", s); $fflush(fd); end
    endfunction

    initial begin
        asm = new();
        if (!$value$plusargs("RSI_OUT=%s", out_name)) out_name = OUT_PREFIX;
        out_name = $sformatf("%s_rsi%0d.txt", out_name, RSI_ID);
        fd = $fopen(out_name, "w");
        $display("[RSI%0d] model hazir (cikti dosyasi: %s)", RSI_ID, out_name);
        logf($sformatf("# RSI%0d modeli (v1.0.7). Zamanlar ns. Veri float32 I/Q.", RSI_ID));
        if (RSI_ID < 1 || RSI_ID > 3) $error("[RSI] RSI_ID 1..3 olmali: %0d", RSI_ID);
    end

    always @(posedge user_clk) begin
        if (asm != null && !user_reset && s_axis_rq_tvalid && s_axis_rq_tready[0]) begin
            rx_done = asm.push_beat(s_axis_rq_tdata, s_axis_rq_tkeep[7:0], s_axis_rq_tlast, s_axis_rq_tuser, rx_pkt);
            if (rx_done) begin
                tlp_total++;
                if (rx_pkt.req_type != REQ_TYPE_MEMWR) begin
                    $warning("[RSI%0d] %s beklenmiyordu (yalniz MemWr), atildi.", RSI_ID, rx_pkt.type_name());
                end else if (rx_pkt.payload.size() != 0) begin
                    store_pkt(rx_pkt);
                end
            end
        end
    end

    // Paketi 4 baytlik kelimeler olarak hafizaya yazar (bayt etkinligi: ilk/son kelime kismi olabilir)
    function automatic void store_pkt(rq_pkt p);
        bit [63:0] a;
        bit [31:0] w;
        int unsigned nd;
        nd = p.payload.size() / 4;
        wr_count++;
        if (p.first_be != 4'hF || (p.last_be != 4'hF && nd > 1)) partial_be_warn++;
        for (int unsigned i = 0; i < nd; i++) begin
            if (mem.size() >= MAX_WORDS && !mem.exists((p.addr >> 2) + i)) begin
                dropped++;
            end else begin
                w = {p.payload[4*i+3], p.payload[4*i+2], p.payload[4*i+1], p.payload[4*i]};
                mem[(p.addr >> 2) + i] = w;
            end
        end
    endfunction

    // ---------------- MSI (sim_model_cpu ile ayni) ----------------
    logic [31:0] msi_int_d = '0;
    logic [31:0] msi_pend  = '0;
    logic [31:0] irq_vec   = '0;
    logic        msi_req   = 1'b0;
    logic [1:0]  msi_dly   = 2'b00;
    initial cfg_interrupt_msi_sent = 1'b0;
    always @(posedge user_clk) begin
        msi_int_d              <= cfg_interrupt_msi_int;
        msi_req                <= |(cfg_interrupt_msi_int & ~msi_int_d);
        msi_dly                <= {msi_dly[0], msi_req};
        cfg_interrupt_msi_sent <= msi_dly[1];
        if (|(cfg_interrupt_msi_int & ~msi_int_d))
            msi_pend = msi_pend | (cfg_interrupt_msi_int & ~msi_int_d);
        if (msi_dly[1]) begin
            irq_vec  = irq_vec | msi_pend;
            msi_pend = '0;
        end
    end

    bit          irq_flag = 1'b0;
    logic [31:0] isr_vec;
    always @(posedge user_clk)
        if (cfg_interrupt_msi_sent) irq_flag = 1'b1;

    int unsigned isr_count = 0;
    initial begin
        forever begin
            wait (irq_flag && asm != null);
            irq_flag = 1'b0;
            wait (!asm.collecting);
            #(ISR_LATENCY_NS);
            wait (!asm.collecting);
            isr_vec = irq_vec;
            irq_vec = '0;
            isr_count++;
            run_isr(isr_vec);
        end
    end

    // ---------------- ISR: MSI1..MSI4 ----------------
    task automatic run_isr(bit [31:0] vec);
        logf($sformatf("%0t ISR #%0d vektor=%h (MSI1=%b MSI2=%b MSI3=%b MSI4=%b)", $time, isr_count, vec,
                       vec[0], vec[1], vec[2], vec[3]));
        $display("[%0t] [RSI%0d] ISR #%0d vektor=%h", $time, RSI_ID, isr_count, vec);
        if (vec[2]) logf($sformatf("%0t MSI3: SHOB->SIFPGA kanal verisi EKSIK geldi (bu surumde hata enjeksiyonu yok; beklenmiyordu)", $time));
        if (vec[3]) logf($sformatf("%0t MSI4: SHOB->SIFPGA kanal verisi GELMEDI (bu surumde hata enjeksiyonu yok; beklenmiyordu)", $time));
        if (vec[31:4] != 0) logf($sformatf("%0t UYARI tanimsiz MSI bitleri: %h", $time, vec & 32'hFFFF_FFF0));
        if (vec[0] || vec[1]) process_round(vec[0] && !vec[1]);
    endtask

    // ---------------- float32 -> tamsayi (tam olmayan degerleri reddeder) ----------------
    // Sade tutuldu (xsim): output argumanli fonksiyon yok; gecerlilik ve deger ayri fonksiyonlarda.
    function automatic bit f32_ok(bit [31:0] f);
        int e, sh;
        if (f[30:0] == 31'd0) return 1'b1;               // +-0
        e = int'(f[30:23]);
        if (e == 255 || e == 0) return 1'b0;             // inf/NaN, denormal
        sh = e - 127 - 23;
        if (sh > 38) return 1'b0;
        if (sh < 0) begin
            if (-sh > 23) return 1'b0;
            if (({1'b1, f[22:0]} & ((24'd1 << (-sh)) - 24'd1)) != 24'd0) return 1'b0;   // kesirli
        end
        return 1'b1;
    endfunction

    function automatic longint f32_val(bit [31:0] f);
        int        e, sh;
        bit [63:0] mag;
        if (f[30:0] == 31'd0) return 0;
        e  = int'(f[30:23]);
        sh = e - 127 - 23;
        if (sh >= 0) mag = 64'({1'b1, f[22:0]}) << sh;
        else         mag = 64'({1'b1, f[22:0]}) >> (-sh);
        return f[31] ? -longint'(mag) : longint'(mag);
    endfunction

    // kod = ((m+1)<<15) | n : gecerli mi, m, n
    function automatic bit code_ok(longint code);
        if (code <= 0) return 1'b0;
        if ((code >> 15) < 1 || (code >> 15) > 960) return 1'b0;
        return 1'b1;
    endfunction
    function automatic int code_m(longint code);
        return int'(code >> 15) - 1;
    endfunction
    function automatic int code_n(longint code);
        return int'(code & 64'h7FFF);
    endfunction

    // anahtarlar (artan adres) modul duzeyinde tutulur
    bit [63:0]   keys_m [$];
    int          beam_n_m [int];             // huzme -> ornek sayisi
    bit          seen_mn_m [bit [63:0]];     // anahtar {huzme, ornek}: goruldu mu
    int          beam_list_m [$];            // bu turda gorulen huzmeler (artan sirayla degil, ilk gorulme sirasiyla)

    // Verilen carpan k icin kac I/Q cifti gecerli desen? (adres sirasina gore ardisik kelimeler)
    function automatic int count_valid(int k);
        int     ok;
        longint vi, vq;
        ok = 0;
        for (int i = 0; i + 1 < keys_m.size(); i += 2) begin
            if (f32_ok(mem[keys_m[i]]) && f32_ok(mem[keys_m[i+1]])) begin
                vi = f32_val(mem[keys_m[i]]);
                vq = f32_val(mem[keys_m[i+1]]);
                if (vi > 0 && (vi % k) == 0 && vq == -vi && code_ok(vi / k)) ok++;
            end
        end
        return ok;
    endfunction

    function automatic int ks(int j);      // denenen birlestirme carpanlari (once toplam)
        if (j == 0) return 3;
        else if (j == 1) return 1;
        else return 2;
    endfunction

    int round_no = 0;

    // ---------------- Turu kapat: coz, dogrula, dok, temizle ----------------
    task automatic process_round(bit basarili);
        bit [63:0]   cur;
        int          tur, nsamp, npair, errors, warns, i, j;
        bit          has_t;
        bit [63:0]   start_expected, start_actual;
        int          k_best, best_ok, ok_k;
        string       rule;
        longint      vi, vq, code;
        int          m, n, prev_m, prev_n, nbeams, detail_n, nk_exp, bn;
        int          dup_samples, gaps, bad_samples, mn_inc_n, mn_inc_m;
        string       layout, sl;
        bit          dogru, have_prev;

        // yerel olmayan durum: acikca temizle
        keys_m.delete(); beam_n_m.delete(); seen_mn_m.delete(); beam_list_m.delete();
        round_no++;
        tur = rsi_tur_idx[RSI_ID];
        rsi_tur_idx[RSI_ID] = tur + 1;
        has_t = tur_var(tur);
        nk_exp = has_t ? int'(t_nk[RSI_ID][tur]) : 0;
        errors = 0; warns = 0; bad_samples = 0; dup_samples = 0; gaps = 0;
        logf("");
        logf($sformatf("%0t ===== TUR %0d (MSI%0s) =====", $time, tur + 1, basarili ? "1: yazildi" : "2: YAZILAMADI"));

        // ---- anahtarlar (artan adres) ----
        if (mem.first(cur)) begin
            keys_m.push_back(cur);
            while (mem.next(cur)) keys_m.push_back(cur);
        end
        nsamp = keys_m.size();
        logf($sformatf("%0t alinan MemWr=%0d, kelime=%0d (%0d bayt), atilan kelime=%0d, kismi be uyarilari=%0d",
                       $time, wr_count, nsamp, nsamp * 4, dropped, partial_be_warn));
        if (nsamp == 0) begin
            logf($sformatf("%0t HATA bu turda hic veri yazilmamis", $time));
            rsi_report_round(RSI_ID, tur, basarili, 1'b0, 0, 0);
            reset_round();
            return;
        end

        // ---- beklenen baslangic adresi ----
        start_actual = keys_m[0] << 2;
        if (has_t && rsi_start_valid) begin
            start_expected = rsi_start_addr[RSI_ID] + t_off[RSI_ID][tur];
            if (start_actual == start_expected)
                logf($sformatf("%0t ADRES OK: ilk yazilan adres=%h = baslangic(%h) + offset(%h)", $time, start_actual,
                               rsi_start_addr[RSI_ID], t_off[RSI_ID][tur]));
            else begin
                logf($sformatf("%0t ADRES HATA: ilk yazilan adres=%h, beklenen=%h (baslangic %h + offset %h)", $time,
                               start_actual, start_expected, rsi_start_addr[RSI_ID], t_off[RSI_ID][tur]));
                errors++;
            end
        end else begin
            logf($sformatf("%0t ADRES kontrolu yapilamadi (1DEA0001/1DEA0003 bu tur icin senaryoda gorulmedi). ilk adres=%h",
                           $time, start_actual));
            warns++;
        end

        // ---- cift sayida kelime ve bitisiklik ----
        if (nsamp % 2 != 0) begin
            logf($sformatf("%0t HATA kelime sayisi tek (%0d): I/Q ciftleri tamamlanmamis", $time, nsamp));
            errors++;
        end
        for (i = 1; i < nsamp; i++)
            if (keys_m[i] != keys_m[i-1] + 1) begin
                gaps++;
                if (gaps <= 8) logf($sformatf("%0t HATA bosluk: %h sonrasi %h (kelime adresleri)", $time, keys_m[i-1] << 2, keys_m[i] << 2));
            end
        if (gaps != 0) errors++;

        // ---- birlestirme kurali: k = 3 (toplam), 1, 2 ----
        npair = nsamp / 2;
        k_best = 0; best_ok = 0;
        for (j = 0; j < 3; j++) begin
            ok_k = count_valid(ks(j));
            if (ok_k > best_ok) begin best_ok = ok_k; k_best = ks(j); end
            if (ok_k == npair) begin k_best = ks(j); best_ok = ok_k; break; end
        end
        if (k_best == 3)      rule = "TOPLAM (SHOB-1 + SHOB-2)";
        else if (k_best == 1) rule = "yalniz SHOB-1";
        else if (k_best == 2) rule = "yalniz SHOB-2";
        else                  rule = "TANINMADI";
        logf($sformatf("%0t BIRLESTIRME KURALI: %s (carpan=%0d); gecerli ornek=%0d/%0d", $time, rule, k_best, best_ok, npair));
        if (k_best == 0) errors++;
        else if (best_ok != npair) errors++;
        if (k_best != 0 && k_best != 3)
            logf($sformatf("%0t UYARI: carpan 3 (toplam) bekleniyordu, %0d bulundu", $time, k_best));

        // ---- ornek ornek coz: huzme/ornek kapsami, yerlesim ----
        mn_inc_n = 0; mn_inc_m = 0; have_prev = 1'b0; prev_m = 0; prev_n = 0; detail_n = 0;
        for (i = 0; k_best != 0 && i + 1 < nsamp; i += 2) begin
            vi = 0; vq = 0;
            if (f32_ok(mem[keys_m[i]]) && f32_ok(mem[keys_m[i+1]])) begin
                vi = f32_val(mem[keys_m[i]]);
                vq = f32_val(mem[keys_m[i+1]]);
            end
            if (vi > 0 && (vi % k_best) == 0 && vq == -vi && code_ok(vi / k_best)) begin
                code = vi / k_best;
                m = code_m(code);
                n = code_n(code);
                if (seen_mn_m.exists({32'(m), 32'(n)})) dup_samples++;
                seen_mn_m[{32'(m), 32'(n)}] = 1'b1;
                if (beam_n_m.exists(m)) beam_n_m[m] = beam_n_m[m] + 1;
                else begin beam_n_m[m] = 1; beam_list_m.push_back(m); end
                if (have_prev) begin
                    if (m == prev_m && n == prev_n + 1) mn_inc_n++;
                    else if (n == prev_n && m == prev_m + 1) mn_inc_m++;
                end
                prev_m = m; prev_n = n; have_prev = 1'b1;
                if (DETAIL_LINES < 0 || detail_n < DETAIL_LINES) begin
                    detail_n++;
                    logf($sformatf("  adres=%h huzme=%0d ornek=%0d I=%0d Q=%0d", keys_m[i] << 2, m, n, vi, vq));
                end
            end else begin
                bad_samples++;
                if (bad_samples <= 16)
                    logf($sformatf("  HATALI ornek adres=%h I=%h Q=%h (float32 ham)", keys_m[i] << 2, mem[keys_m[i]], mem[keys_m[i+1]]));
            end
        end
        if (bad_samples != 0) begin
            logf($sformatf("%0t HATA %0d ornek gecerli desene uymuyor", $time, bad_samples));
            errors++;
        end
        if (dup_samples != 0) begin
            logf($sformatf("%0t HATA %0d ornek birden cok kez yazilmis", $time, dup_samples));
            errors++;
        end

        // ---- yerlesim ----
        if (mn_inc_n > mn_inc_m)      layout = "HUZME-ANA (once bir huzmenin tum ornekleri, sonra sonraki huzme)";
        else if (mn_inc_m > mn_inc_n) layout = "ORNEK-ANA (her ornek icin tum huzmeler, sonra sonraki ornek)";
        else                          layout = "belirsiz";
        logf($sformatf("%0t YERLESIM: %s (n-artan=%0d, m-artan=%0d)", $time, layout, mn_inc_n, mn_inc_m));

        // ---- huzme listesi ve kapsam ----
        nbeams = beam_list_m.size();
        logf($sformatf("%0t HUZME SAYISI: %0d (beklenen RSI%0d icin %0s)", $time, nbeams, RSI_ID,
                       has_t ? $sformatf("%0d", nk_exp) : "bilinmiyor"));
        if (has_t && nbeams != nk_exp) begin
            logf($sformatf("%0t HATA huzme sayisi beklenenle farkli", $time));
            errors++;
        end
        sl = "  huzme listesi:";
        for (j = 0; j < nbeams; j++) begin
            m  = beam_list_m[j];
            bn = beam_n_m[m];
            if (has_t) begin
                if (bn != int'(t_nsample[tur])) begin
                    logf($sformatf("%0t HATA huzme %0d: %0d ornek var, beklenen N=%0d", $time, m, bn, t_nsample[tur]));
                    errors++;
                end
                if (m >= int'(t_m[tur])) begin
                    logf($sformatf("%0t HATA huzme %0d >= M(%0d)", $time, m, t_m[tur]));
                    errors++;
                end
            end
            rsi_beam_add(tur, m);
            if (j < 128) sl = {sl, $sformatf(" %0d", m)};
            else if (j == 128) sl = {sl, " ..."};
        end
        if (nbeams != 0) logf(sl);

        dogru = (errors == 0);
        logf($sformatf("%0t TUR %0d SONUC: %s (hata=%0d, uyari=%0d)", $time, tur + 1, dogru ? "DOGRU" : "YANLIS", errors, warns));
        $display("[%0t] [RSI%0d] tur %0d: %s, huzme=%0d, kural=%s, hata=%0d", $time, RSI_ID, tur + 1,
                 dogru ? "DOGRU" : "YANLIS", nbeams, rule, errors);
        rsi_report_round(RSI_ID, tur, basarili, dogru, k_best, nbeams);
        reset_round();
    endtask

    function automatic void reset_round();
        mem.delete();
        wr_count = 0;
        dropped = 0;
        partial_be_warn = 0;
    endfunction

    // Toplam sayilar: simulasyon sonunda cagrilabilir
    function automatic void report();
        $display("[RSI%0d] ozet: %0d TLP, %0d tur kapatildi", RSI_ID, tlp_total, round_no);
        logf($sformatf("# OZET: %0d TLP, %0d tur", tlp_total, round_no));
    endfunction
endmodule
