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
//   * SIBFPGA -> RSI mesaj formati (ICD "SHOB HUZME VERISI & SCIT", ID 0x00000002, little-endian):
//       ID(4) | LEN(4, yalniz veri) | HEADER 88 B | HUZME VERISI M kanal x (N adet I float32 + N adet Q float32) | GAC SCIT 1920 B |
//       SHOB SCIT 32 B | SIBFPGA SCIT 16 B | FOOTER 16 B (AAAAAAAA BBBBBBBB CCCCCCCC DDDDDDDD)
//     HEADER: 0 huzme ID(4) | 4 durum(2) | 6 alma huzme sayisi(2) | 8 darbe(4) | 12 ornek(4) | 16 reserved(8) | 24..52 sekiz GAC maskesi |
//             56 SHOB-1 kart(1) | 57 SHOB-2 kart(1) | 58 reserved(30).    N = darbe x ornek, K (kanal sayisi) boyuttan hesaplanir.
//   * Dogrulama deseni SHOB VIP'in urettigi kendini tarif eden desendir: kod = ((m+1)<<15) | (n & 0x7FFF), I = +k*kod, Q = -k*kod;
//     birlestirme kurali k otomatik bulunur (3: SHOB-1+SHOB-2 toplami, 1 ya da 2: yalniz bir SHOB) ve dosyaya yazilir.
//   * Kontroller (RSI basina): baslangic adresi = RSI baslangic adresi (1DEA0001) + offset (1DEA0003); ID = 2; LEN = gelen bayt;
//     header alanlari (huzme ID, darbe, ornek) 1DEA0003 ile ayni; kanal sayisi = 1DEA0003'teki RSI'ye indirilecek huzme sayisi;
//     her kanalda N ornek desene uyar; FOOTER dogru ve mesajin sonunda. Kural bulunamasa da ilk 32 kelime HAM DOKUM olarak yazilir.
//     Turun tum RSI'leri raporlayinca rsi_pkg::rsi_report_round birlesim kontrolu (her huzme 0..M-1 bir kez) yapar.
//   * Cikti: <OUT_PREFIX>_rsi<RSI_ID>.txt ve turlarin ozeti rsi_tur_ozeti.txt (rsi_pkg).
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
        if (vec[2]) begin
            msi3_pending++;
            logf($sformatf("%0t MSI3: SHOB->SIFPGA kanal verisi EKSIK geldi (SIFPGA bildirimi; bu turun verisi bozuk/atlanmis olabilir; son turdan beri %0d kez)", $time, msi3_pending));
        end
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

    // ---------------- mesaj duzeni sabitleri (kelime = 4 bayt) ----------------
    localparam int HDR_WORDS   = 24;     // ID + LEN + HEADER 88 B
    localparam int GAC_WORDS   = 480;    // GAC SCIT 1920 B
    localparam int SHOB_WORDS  = 8;      // SHOB SCIT 32 B
    localparam int SIB_WORDS   = 4;      // SIBFPGA SCIT 16 B
    localparam int FOOT_WORDS  = 4;      // FOOTER 16 B
    localparam int TAIL_WORDS  = GAC_WORDS + SHOB_WORDS + SIB_WORDS + FOOT_WORDS;   // 496

    // modul duzeyinde durum (xsim sadeligi: yerel kuyruk/iliskisel dizi yok; her tur basinda acikca temizlenir)
    bit [63:0]   keys_m [$];                 // bellekteki kelime anahtarlari (artan adres)
    bit [63:0]   base_key = 64'd0;           // mesajin ilk kelimesinin anahtari
    int          kn_K = 0;                   // kanal (huzme) sayisi
    int          kn_N = 0;                   // kanal basina ornek sayisi
    int          beam_list_m [$];            // bu turda gorulen huzmeler (ilk gorulme sirasiyla)
    bit          seen_beam_m [int];          // huzme daha once goruldu mu

    // mesajin i. kelimesi (yoksa 0)
    function automatic bit [31:0] wd(int i);
        if (mem.exists(base_key + 64'(i))) return mem[base_key + 64'(i)];
        else                               return 32'd0;
    endfunction

    // Verilen carpan k icin kac (kanal, ornek) cifti gecerli desen? I blogu ve Q blogu ayri okunur.
    function automatic int count_valid(int k);
        int          ok;
        longint      vi, vq;
        bit [31:0]   wi, wq;
        ok = 0;
        for (int c = 0; c < kn_K; c++)
            for (int n = 0; n < kn_N; n++) begin
                wi = wd(HDR_WORDS + c * 2 * kn_N + n);
                wq = wd(HDR_WORDS + c * 2 * kn_N + kn_N + n);
                if (f32_ok(wi) && f32_ok(wq)) begin
                    vi = f32_val(wi);
                    vq = f32_val(wq);
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

    function automatic string wfmt(bit [31:0] w);
        if (f32_ok(w)) return $sformatf("%h (float=%0d)", w, f32_val(w));
        else           return $sformatf("%h (float tamsayi degil)", w);
    endfunction

    int round_no = 0;
    int msi3_pending = 0;      // v1.0.9: son turdan beri gelen MSI3 sayisi
    int prev_nbytes  = 0;      // v1.0.9: bir onceki turda gelen toplam bayt

    // ---------------- Turu kapat: coz, dogrula, dok, temizle ----------------
    task automatic process_round(bit basarili);
        bit [63:0]   cur;
        int          tur_seq;
        int          pn, msi3_n, lendiff, exp_total;
        bit [31:0]   hid_pk;
        int          tur, nwords, nbytes, errors, warns, i, j, c, n, tail_w, data_bytes;
        int          k_best, best_ok, ok_k, npair, nbeams, detail_n, bad_samples, dup_beams, gaps, nk_exp;
        int          chan_m, mm, dem, nz;
        bit          has_t, dogru, okf, foot_ok;
        bit [63:0]   start_expected, start_actual;
        longint      vi, vq, code;
        bit [31:0]   id, len, hid, w3, darbe, ornek, wi, wq;
        int          durum, alma;
        string       rule, sl;

        // yerel olmayan durum: acikca temizle
        keys_m.delete(); beam_list_m.delete(); seen_beam_m.delete();
        kn_K = 0; kn_N = 0;
        round_no++;
        tur = rsi_tur_idx[RSI_ID];                 // sirada beklenen tur (eslesme asagida huzme ID'ye gore duzeltilir)
        errors = 0; warns = 0; bad_samples = 0; dup_beams = 0; gaps = 0; nbeams = 0; k_best = 0; best_ok = 0;

        // ---- anahtarlar (artan adres) ----
        if (mem.first(cur)) begin
            keys_m.push_back(cur);
            while (mem.next(cur)) keys_m.push_back(cur);
        end
        nwords = keys_m.size();
        nbytes = nwords * 4;
        pn = prev_nbytes;  prev_nbytes = nbytes;        // v1.0.9: tanilama
        msi3_n = msi3_pending;  msi3_pending = 0;

        // ---- v1.0.9: tur eslemesi huzme ID'ye gore ----
        // Mesaj ID=2 ise header'daki huzme ID'sini tasiyan (bu RSI'ye veri verilecek) ilk tur secilir; arada kalan
        // turler "VERI GELMEDI" sayilir (SIFPGA reddetmis/yazmamis). ID bulunamazsa sirada beklenen tur kullanilir.
        tur_seq = tur;
        if (nwords >= 3) begin
            base_key = keys_m[0];
            if (wd(0) == 32'h00000002) begin
                hid_pk = wd(2);
                for (j = tur; j < t_count; j++)
                    if (t_hid[j] == hid_pk && t_nk[RSI_ID][j] > 0) begin
                        for (i = tur; i < j; i++)
                            if (t_nk[RSI_ID][i] > 0) rsi_report_missing(RSI_ID, i);
                        tur = j;
                        break;
                    end
            end
        end
        rsi_tur_idx[RSI_ID] = tur + 1;
        rsi_set_msi3(RSI_ID, tur, msi3_n);
        rsi_set_lendiff(RSI_ID, tur, 0);
        has_t = tur_var(tur);
        nk_exp = has_t ? int'(t_nk[RSI_ID][tur]) : 0;
        logf("");
        logf($sformatf("%0t ===== TUR %0d (MSI%0s) =====", $time, tur + 1, basarili ? "1: yazildi" : "2: YAZILAMADI"));
        if (tur != tur_seq)
            logf($sformatf("%0t ESLESME: huzme ID ile tur %0d secildi (sirada beklenen tur %0d; aradaki %0d tur icin veri gelmedi)",
                           $time, tur + 1, tur_seq + 1, tur - tur_seq));
        logf($sformatf("%0t alinan MemWr=%0d, kelime=%0d (%0d bayt), atilan kelime=%0d, kismi be uyarilari=%0d",
                       $time, wr_count, nwords, nbytes, dropped, partial_be_warn));
        if (msi3_n != 0)
            logf($sformatf("%0t TESHIS: bu turdan once SIFPGA %0d kez MSI3 (SHOB verisi eksik) bildirdi", $time, msi3_n));
        if (nwords == 0) begin
            logf($sformatf("%0t HATA bu turda hic veri yazilmamis", $time));
            rsi_report_round(RSI_ID, tur, basarili, 1'b0, 0, 0);
            reset_round();
            return;
        end
        base_key = keys_m[0];
        start_actual = base_key << 2;

        // ---- beklenen baslangic adresi ----
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
            logf($sformatf("%0t ADRES kontrolu yapilamadi (1DEA0001/1DEA0003 bu tur icin senaryoda gorulmedi; VIP_RSI tanimli mi?). ilk adres=%h",
                           $time, start_actual));
            warns++;
        end

        // ---- bitisiklik ----
        for (i = 1; i < nwords; i++)
            if (keys_m[i] != keys_m[i-1] + 1) begin
                gaps++;
                if (gaps <= 8) logf($sformatf("%0t HATA bosluk: %h sonrasi %h (kelime adresleri)", $time, keys_m[i-1] << 2, keys_m[i] << 2));
            end
        if (gaps != 0) errors++;

        // ---- HAM DOKUM: kural/format bulunamasa da ilk kelimeler her zaman yazilir ----
        logf($sformatf("%0t HAM DOKUM (ilk %0d kelime: [kelime no] adres hex (float yorumu)):", $time, (nwords < 32) ? nwords : 32));
        for (i = 0; i < nwords && i < 32; i++)
            logf($sformatf("  [%0d] %h  %s", i, (base_key + 64'(i)) << 2, wfmt(wd(i))));

        // ---- ID ve LEN ----
        id  = wd(0);
        len = wd(1);
        logf($sformatf("%0t MESAJ: ID=%h LEN=%0d (toplam %0d bayt beklenir, gelen %0d bayt)", $time, id, len, 8 + len, nbytes));
        if (id != 32'h00000002) begin
            logf($sformatf("%0t HATA mesaj ID 00000002 olmali, gelen %h", $time, id));
            errors++;
        end
        lendiff = nbytes - (8 + int'(len));
        rsi_set_lendiff(RSI_ID, tur, lendiff);
        if (8 + len != nbytes) begin
            logf($sformatf("%0t HATA LEN uyusmuyor: 8 + LEN = %0d, gelen %0d bayt", $time, 8 + len, nbytes));
            errors++;
            logf($sformatf("%0t TESHIS: gelen bayt - (8+LEN) = %0d bayt (%0s)", $time, lendiff,
                           (lendiff > 0) ? "fazla: MSI'siz onceki (reddedilmis) turun artigi olabilir"
                                         : "eksik: mesaj kesilmis ya da yazim eksik kalmis"));
            if (nbytes == pn && pn != 0)
                logf($sformatf("%0t TESHIS: gelen boyut (%0d bayt) bir onceki turun boyutuyla ayni: SIFPGA mesaj uzunlugunu guncellememis olabilir", $time, nbytes));
        end
        if (has_t) begin
            exp_total = (HDR_WORDS + TAIL_WORDS) * 4 + 8 * int'(t_nsample[tur]) * nk_exp;
            if (8 + int'(len) != exp_total)
                logf($sformatf("%0t TESHIS: 1DEA0003'e gore beklenen toplam %0d bayt (N=%0d, K=%0d); LEN'deki toplam %0d bayt", $time,
                               exp_total, t_nsample[tur], nk_exp, 8 + int'(len)));
        end

        // ---- HEADER (88 B): kelime 2..23 ----
        hid    = wd(2);
        w3     = wd(3);
        durum  = int'(w3[15:0]);
        alma   = int'(w3[31:16]);
        darbe  = wd(4);
        ornek  = wd(5);
        logf($sformatf("%0t HEADER: huzme_id=%h durum=%0d (%0s) alma_huzme=%0d darbe=%0d ornek=%0d (N=%0d)", $time, hid, durum,
                       (durum == 1) ? "HO" : ((durum == 0) ? "Bypass" : "GECERSIZ"), alma, darbe, ornek, darbe * ornek));
        sl = "  GAC kullanim maskeleri (1-30,31-60,...,211-240):";
        for (j = 0; j < 8; j++) sl = {sl, $sformatf(" %h", wd(8 + j))};
        logf(sl);
        logf($sformatf("  SHOB-1 kart=%h SHOB-2 kart=%h", wd(16) & 32'hFF, (wd(16) >> 8) & 32'hFF));
        if (durum != 0 && durum != 1) begin
            logf($sformatf("%0t HATA durum 0 (Bypass) ya da 1 (HO) olmali", $time));
            errors++;
        end
        nz = 0;
        if (wd(6) != 0 || wd(7) != 0 || (wd(16) >> 16) != 0) nz = 1;
        for (j = 17; j < 24; j++) if (wd(j) != 0) nz = 1;
        if (nz != 0) begin
            logf($sformatf("%0t UYARI header reserved alani sifir degil", $time));
            warns++;
        end
        for (j = 0; j < 8; j++)
            if ((wd(8 + j) >> 30) != 0) begin
                logf($sformatf("%0t UYARI GAC maskesi %0d: bit 30/31 reserved (0 olmali)", $time, j));
                warns++;
            end
        if (has_t) begin
            if (hid != t_hid[tur]) begin
                logf($sformatf("%0t HATA huzme ID %h, 1DEA0003'te %h", $time, hid, t_hid[tur]));
                errors++;
            end
            if (darbe != t_darbe[tur] || ornek != t_ornek[tur]) begin
                logf($sformatf("%0t HATA darbe/ornek (%0d/%0d), 1DEA0003'te (%0d/%0d)", $time, darbe, ornek, t_darbe[tur], t_ornek[tur]));
                errors++;
            end
            if (alma != int'(t_m[tur]) && alma != nk_exp) begin
                logf($sformatf("%0t UYARI alma huzme sayisi %0d: 1DEA0003 M=%0d, bu RSI icin kanal=%0d (hicbiri degil)", $time, alma, t_m[tur], nk_exp));
                warns++;
            end
        end

        // ---- kanal sayisi: gelen boyuttan ----
        kn_N = int'(darbe) * int'(ornek);
        data_bytes = nbytes - (HDR_WORDS + TAIL_WORDS) * 4;
        if (kn_N <= 0 || data_bytes <= 0 || (data_bytes % (8 * kn_N)) != 0) begin
            logf($sformatf("%0t HATA kanal sayisi hesaplanamadi: N=%0d, huzme verisi bolumu %0d bayt (8*N*K olmali)", $time, kn_N, data_bytes));
            errors++;
            kn_K = 0;
        end else begin
            kn_K = data_bytes / (8 * kn_N);
        end
        logf($sformatf("%0t KANAL SAYISI K=%0d (beklenen RSI%0d icin %0s), N=%0d", $time, kn_K, RSI_ID,
                       has_t ? $sformatf("%0d", nk_exp) : "bilinmiyor", kn_N));
        if (has_t && kn_K != nk_exp) begin
            logf($sformatf("%0t HATA kanal sayisi beklenenle farkli", $time));
            errors++;
        end
        logf($sformatf("%0t YERLESIM: KANAL-ANA (her kanal icin once N adet I, sonra N adet Q, float32); sonra GAC SCIT, SHOB SCIT, SIBFPGA SCIT, FOOTER", $time));

        // ---- birlestirme kurali: k = 3 (toplam), 1, 2 ----
        npair = kn_K * kn_N;
        if (kn_K > 0) begin
            for (j = 0; j < 3; j++) begin
                ok_k = count_valid(ks(j));
                if (ok_k > best_ok) begin best_ok = ok_k; k_best = ks(j); end
                if (ok_k == npair) begin k_best = ks(j); best_ok = ok_k; break; end
            end
        end
        if (k_best == 3)      rule = "TOPLAM (SHOB-1 + SHOB-2)";
        else if (k_best == 1) rule = "yalniz SHOB-1";
        else if (k_best == 2) rule = "yalniz SHOB-2";
        else                  rule = "TANINMADI";
        logf($sformatf("%0t BIRLESTIRME KURALI: %s (carpan=%0d); gecerli ornek=%0d/%0d", $time, rule, k_best, best_ok, npair));
        if (kn_K > 0) begin
            if (k_best == 0) errors++;
            else if (best_ok != npair) errors++;
        end
        if (k_best != 0 && k_best != 3)
            logf($sformatf("%0t UYARI: carpan 3 (toplam) bekleniyordu, %0d bulundu", $time, k_best));

        // ---- kanal kanal coz: her kanalda N ornek, ayni huzme, ornek sirasi 0..N-1 ----
        detail_n = 0;
        for (c = 0; c < kn_K && k_best != 0; c++) begin
            chan_m = -1;
            for (n = 0; n < kn_N; n++) begin
                wi = wd(HDR_WORDS + c * 2 * kn_N + n);
                wq = wd(HDR_WORDS + c * 2 * kn_N + kn_N + n);
                okf = 1'b0;
                vi = 0; vq = 0;
                if (f32_ok(wi) && f32_ok(wq)) begin
                    vi = f32_val(wi);
                    vq = f32_val(wq);
                    okf = (vi > 0 && (vi % k_best) == 0 && vq == -vi && code_ok(vi / k_best));
                end
                if (okf) begin
                    code = vi / k_best;
                    mm = code_m(code);
                    if (chan_m < 0) chan_m = mm;
                    if (mm != chan_m || code_n(code) != n) okf = 1'b0;
                end
                if (!okf) begin
                    bad_samples++;
                    if (bad_samples <= 16)
                        logf($sformatf("  HATALI ornek kanal=%0d ornek=%0d I=%h Q=%h (float32 ham)", c, n, wi, wq));
                end else if (DETAIL_LINES < 0 || detail_n < DETAIL_LINES) begin
                    detail_n++;
                    logf($sformatf("  kanal=%0d huzme=%0d ornek=%0d I=%0d Q=%0d", c, chan_m, n, vi, vq));
                end
            end
            if (chan_m >= 0) begin
                if (seen_beam_m.exists(chan_m)) dup_beams++;
                else begin seen_beam_m[chan_m] = 1'b1; beam_list_m.push_back(chan_m); end
            end
        end
        if (bad_samples != 0) begin
            logf($sformatf("%0t HATA %0d ornek gecerli desene uymuyor ya da kanalin huzme/ornek sirasi bozuk", $time, bad_samples));
            errors++;
        end
        if (dup_beams != 0) begin
            logf($sformatf("%0t HATA %0d huzme birden cok kanalda yazilmis", $time, dup_beams));
            errors++;
        end

        // ---- huzme listesi ----
        nbeams = beam_list_m.size();
        logf($sformatf("%0t HUZME SAYISI: %0d", $time, nbeams));
        sl = "  huzme listesi (kanal sirasiyla):";
        for (j = 0; j < nbeams; j++) begin
            mm = beam_list_m[j];
            if (has_t && mm >= int'(t_m[tur])) begin
                logf($sformatf("%0t HATA huzme %0d >= M(%0d)", $time, mm, t_m[tur]));
                errors++;
            end
            rsi_beam_add(tur, mm);
            if (j < 128) sl = {sl, $sformatf(" %0d", mm)};
            else if (j == 128) sl = {sl, " ..."};
        end
        if (nbeams != 0) logf(sl);

        // ---- SCIT bolumleri ve FOOTER ----
        tail_w = (kn_K > 0) ? (HDR_WORDS + 2 * kn_K * kn_N) : (nwords - TAIL_WORDS);
        if (tail_w < HDR_WORDS || nwords != tail_w + TAIL_WORDS) begin
            logf($sformatf("%0t HATA mesaj sonu: %0d kelime geldi, kuyruk dahil %0d kelime beklenir", $time, nwords, tail_w + TAIL_WORDS));
            errors++;
        end
        if (nwords >= tail_w + TAIL_WORDS && tail_w >= HDR_WORDS) begin
            nz = 0;
            for (j = 0; j < GAC_WORDS; j++) if (wd(tail_w + j) != 0) nz++;
            logf($sformatf("%0t GAC SCIT: %0d kelime (1920 B), sifir olmayan kelime=%0d", $time, GAC_WORDS, nz));
            sl = "  SHOB SCIT (SHOB-1 | SHOB-2):";
            for (j = 0; j < SHOB_WORDS; j++) sl = {sl, $sformatf(" %h", wd(tail_w + GAC_WORDS + j))};
            logf(sl);
            sl = "  SIBFPGA SCIT:";
            for (j = 0; j < SIB_WORDS; j++) sl = {sl, $sformatf(" %h", wd(tail_w + GAC_WORDS + SHOB_WORDS + j))};
            logf(sl);
            dem = tail_w + GAC_WORDS + SHOB_WORDS + SIB_WORDS;
            foot_ok = (wd(dem) == 32'hAAAAAAAA) && (wd(dem + 1) == 32'hBBBBBBBB) && (wd(dem + 2) == 32'hCCCCCCCC) && (wd(dem + 3) == 32'hDDDDDDDD);
            logf($sformatf("%0t FOOTER: %h %h %h %h -> %0s", $time, wd(dem), wd(dem + 1), wd(dem + 2), wd(dem + 3), foot_ok ? "OK" : "HATA (AAAAAAAA BBBBBBBB CCCCCCCC DDDDDDDD beklenir)"));
            if (!foot_ok) errors++;
        end

        dogru = (errors == 0);
        logf($sformatf("%0t TUR %0d SONUC: %s (hata=%0d, uyari=%0d)", $time, tur + 1, dogru ? "DOGRU" : "YANLIS", errors, warns));
        $display("[%0t] [RSI%0d] tur %0d: %s, kanal=%0d, kural=%s, hata=%0d", $time, RSI_ID, tur + 1,
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
        rsi_flush_missing(RSI_ID);   // v1.0.9: hic veri gelmeyen turlar
        $display("[RSI%0d] ozet: %0d TLP, %0d tur kapatildi", RSI_ID, tlp_total, round_no);
        logf($sformatf("# OZET: %0d TLP, %0d tur", tlp_total, round_no));
    endfunction
endmodule
