`timescale 1ns / 1ps

// =====================================================================
// rsi_pkg (v1.0.7): RSI ortak durumu - CPU VIP surucusu ile RSI modelleri arasinda paylasilir
//
// cpu_pkg'den AYRI tutuldu: RSI kullanilmiyorsa bu dosya projeye eklenmeyebilir (derleme sirasi: cpu_pkg, rsi_pkg, scn_pkg).
// scn_pkg'in izleyici cagrisi yalnizca `VIP_RSI tanimliysa derlenir (varsayilan: yok).
// =====================================================================
package rsi_pkg;
    import cpu_pkg::bytes_to_val;

    // =================================================================
    // v1.0.7: RSI ortak durumu
    //
    // CPU VIP'in senaryo surucusu, FPGA'ya giden iki konfigurasyon mesajini dinler:
    //   1DEA0001 (PCIe adres atama)  : veri[96..119] = RSI1/RSI2/RSI3 veri baslangic adresleri (3 x 8 B)
    //   1DEA0003 (SIFPGA huzpar)     : RSI offset'leri, huzme ID, huzme/darbe/ornek sayisi, RSI basina huzme sayisi
    // RSI modelleri (sim_model_rsi) bu bilgiyi buradan okur (ayni simulasyon icinde paylasilan paket degiskenleri).
    // Her 1DEA0003 bir "tur"dur; RSI'ler turlari sirayla tuketir (her MSI1/MSI2 bir turu kapatir).
    // =================================================================
    localparam int NRSI = 3;
    localparam bit [31:0] ID_ADRES_ATAMA   = 32'h1DEA0001;
    localparam bit [31:0] ID_SIFPGA_HUZPAR = 32'h1DEA0003;

    bit [63:0] rsi_start_addr [1:3];       // RSI veri baslangic adresleri (1DEA0001)
    bit        rsi_start_valid = 1'b0;

    class huzme_tur;
        bit [63:0]   offset [1:3];         // RSI1/2/3 veri adres offset'i
        bit [31:0]   huzme_id;
        int unsigned m;                    // SIFPGA alma huzme sayisi
        int unsigned darbe;                // toplam darbe sayisi
        int unsigned ornek;                // darbedeki ornek sayisi
        int unsigned nsample;              // N = darbe * ornek (huzme basina ornek sayisi)
        bit [7:0]    shob_use;             // bit0 SHOB-1, bit1 SHOB-2
        bit [7:0]    mode;                 // 0: HO (SHO), 1: Bypass
        int unsigned n_k [1:3];            // RSI basina indirilecek huzme ("kanal") sayisi
        longint      t_ns;
        function new();
            for (int k = 1; k <= 3; k++) begin offset[k] = 0; n_k[k] = 0; end
            huzme_id = 0; m = 0; darbe = 0; ornek = 0; nsample = 0; shob_use = 0; mode = 0; t_ns = 0;
        endfunction
    endclass

    huzme_tur    turlar[$];                // senaryodan gelen turlar (sirayla)
    int unsigned rsi_tur_idx [1:3] = '{0, 0, 0};   // her RSI'nin kapattigi tur sayisi

    // Surucunun (scn_pkg::driver) her TLP icin cagirdigi izleyici. cont=1 ise bolunmus mesajin devam paketidir.
    function automatic void track_cfg_msgs(bit [7:0] pkt[], bit cont);
        bit [63:0] id;
        huzme_tur  t;
        if (cont || pkt.size() < 24) return;
        id = bytes_to_val(pkt, 16, 4, 1'b0);
        if (id[31:0] == ID_ADRES_ATAMA && pkt.size() >= 24 + 120) begin
            for (int k = 1; k <= NRSI; k++)
                rsi_start_addr[k] = bytes_to_val(pkt, 24 + 96 + 8 * (k - 1), 8, 1'b0);
            rsi_start_valid = 1'b1;
            $display("[RSI] adres atama: RSI1=%h RSI2=%h RSI3=%h", rsi_start_addr[1], rsi_start_addr[2], rsi_start_addr[3]);
        end else if (id[31:0] == ID_SIFPGA_HUZPAR && pkt.size() >= 24 + 39) begin
            t = new();
            for (int k = 1; k <= NRSI; k++) t.offset[k] = bytes_to_val(pkt, 24 + 8 * (k - 1), 8, 1'b0);
            t.huzme_id = bytes_to_val(pkt, 24 + 24, 4, 1'b0);
            t.m        = bytes_to_val(pkt, 24 + 28, 2, 1'b0);
            t.darbe    = bytes_to_val(pkt, 24 + 30, 2, 1'b0);
            t.ornek    = bytes_to_val(pkt, 24 + 32, 2, 1'b0);
            t.nsample  = t.darbe * t.ornek;
            t.shob_use = pkt[24 + 34];
            t.mode     = pkt[24 + 35];
            for (int k = 1; k <= NRSI; k++) t.n_k[k] = pkt[24 + 35 + k];
            t.t_ns     = $time;
            turlar.push_back(t);
            $display("[RSI] tur #%0d (1DEA0003): huzme_id=%h M=%0d darbe=%0d ornek=%0d N=%0d n_k=%0d/%0d/%0d offset=%h/%h/%h",
                     turlar.size(), t.huzme_id, t.m, t.darbe, t.ornek, t.nsample, t.n_k[1], t.n_k[2], t.n_k[3],
                     t.offset[1], t.offset[2], t.offset[3]);
        end
    endfunction

    // ---- tur ozeti: her RSI kendi turunu raporlar; hepsi raporlayinca birlesim kontrolu yapilir ----
    class tur_rapor;
        bit          reported [1:3];
        bit          basarili [1:3];       // MSI1 ile mi kapandi
        bit          dogru    [1:3];       // RSI'nin kendi kontrolleri gecti mi
        int unsigned nbeam    [1:3];
        string       rule     [1:3];
        int unsigned beam_cnt [];               // huzme sirasi -> kac RSI'de goruldu (dinamik dizi)
        bit          printed;
        function new();
            for (int k = 1; k <= 3; k++) begin reported[k] = 0; basarili[k] = 0; dogru[k] = 0; nbeam[k] = 0; rule[k] = ""; end
            printed = 0;
        endfunction
    endclass

    tur_rapor raporlar[$];
    int       rsi_sum_fd = 0;

    function automatic void rsi_sum_log(string s);
        if (rsi_sum_fd == 0) begin
            rsi_sum_fd = $fopen("rsi_tur_ozeti.txt", "w");
            if (rsi_sum_fd != 0) begin
                $fdisplay(rsi_sum_fd, "# RSI tur ozeti (v1.0.7): her satir bir huzme turu; RSI modelleri raporlayinca yazilir");
            end
        end
        if (rsi_sum_fd != 0) begin
            $fdisplay(rsi_sum_fd, "%s", s);
            $fflush(rsi_sum_fd);
        end
    endfunction

    // RSI 'rsi' kendi 'tur' (0 tabanli) turunu raporlar. beams: bu RSI'de gorulen huzme sirasi listesi.
    function automatic void rsi_report_round(int rsi, int tur, bit basarili, bit dogru, string rule,
                                             int unsigned beams[$]);
        tur_rapor    r;
        huzme_tur    t;
        bit          all_in;
        bit          all_ok;
        int unsigned expected_beams;
        int unsigned missing, dup;
        string       line;
        while (raporlar.size() <= tur) begin
            r = new();
            raporlar.push_back(r);
        end
        r = raporlar[tur];
        r.reported[rsi] = 1'b1;
        r.basarili[rsi] = basarili;
        r.dogru[rsi]    = dogru;
        r.rule[rsi]     = rule;
        r.nbeam[rsi]    = beams.size();
        foreach (beams[i]) begin
            if (r.beam_cnt.size() <= beams[i]) r.beam_cnt = new[beams[i] + 1](r.beam_cnt);   // buyut, eskileri koru, yenileri 0
            r.beam_cnt[beams[i]]++;
        end
        t = (tur < turlar.size()) ? turlar[tur] : null;
        // hangi RSI'lerin raporlamasi bekleniyor: n_k > 0 olanlar (yapilandirma yoksa raporlayanlar)
        all_in = 1'b1;
        for (int k = 1; k <= NRSI; k++)
            if (t != null && t.n_k[k] > 0 && !r.reported[k]) all_in = 1'b0;
        if (t == null) all_in = (r.reported[1] || r.reported[2] || r.reported[3]);
        if (!all_in || r.printed) return;
        r.printed = 1'b1;

        all_ok = 1'b1;
        line = $sformatf("TUR %0d", tur + 1);
        if (t != null) line = {line, $sformatf(" huzme_id=%h M=%0d N=%0d", t.huzme_id, t.m, t.nsample)};
        for (int k = 1; k <= NRSI; k++)
            if (r.reported[k]) begin
                line = {line, $sformatf(" | RSI%0d: %0s huzme=%0d %0s", k, r.basarili[k] ? "YAZILDI" : "YAZILAMADI",
                                        r.nbeam[k], r.dogru[k] ? "DOGRU" : "YANLIS")};
                if (!r.basarili[k] || !r.dogru[k]) all_ok = 1'b0;
            end
        rsi_sum_log(line);
        if (all_ok && t != null) begin
            // birlesim: 0..M-1 her huzme tam bir kez, RSI'ler arasinda
            expected_beams = t.m;
            missing = 0; dup = 0;
            for (int unsigned b = 0; b < expected_beams; b++) begin
                if (b >= r.beam_cnt.size()) missing++;
                else if (r.beam_cnt[b] == 0) missing++;
                else if (r.beam_cnt[b] > 1) dup++;
            end
            rsi_sum_log($sformatf("  birlesim: %0d huzme bekleniyor, eksik=%0d, birden cok RSI'de=%0d, birlesim kurali: RSI1=%0s RSI2=%0s RSI3=%0s -> %0s",
                                  expected_beams, missing, dup, r.rule[1], r.rule[2], r.rule[3],
                                  (missing == 0 && dup == 0) ? "DOGRU" : "YANLIS"));
        end else if (!all_ok) begin
            rsi_sum_log("  tur sonucu: BASARISIZ ya da YANLIS (ayrintilar rsiN_out.txt dosyalarinda)");
        end
    endfunction

endpackage
