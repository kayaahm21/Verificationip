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
    // v1.0.7: RSI ortak durumu (sinifsiz, yalniz duz diziler: xsim 2020.2 elaborate cokmesine karsi sade tutuldu)
    //
    // CPU VIP'in senaryo surucusu, FPGA'ya giden iki konfigurasyon mesajini dinler:
    //   1DEA0001 (PCIe adres atama)  : veri[96..119] = RSI1/RSI2/RSI3 veri baslangic adresleri (3 x 8 B)
    //   1DEA0003 (SIFPGA huzpar)     : RSI offset'leri, huzme ID, huzme/darbe/ornek sayisi, RSI basina huzme sayisi
    // RSI modelleri (sim_model_rsi) bu bilgiyi buradan okur. Her 1DEA0003 bir "tur"dur (0 tabanli indeks);
    // RSI'ler turlari sirayla tuketir (her MSI1/MSI2 bir turu kapatir).
    // Dizi indeksleri: RSI 1..3, tur 0..MAXR-1, huzme 0..MAXB-1.
    // =================================================================
    localparam int NRSI = 3;
    localparam int MAXR = 256;     // en cok tur
    localparam int MAXB = 1024;    // en cok huzme (Bypass M=960 dahil)
    localparam bit [31:0] ID_ADRES_ATAMA   = 32'h1DEA0001;
    localparam bit [31:0] ID_SIFPGA_HUZPAR = 32'h1DEA0003;

    bit [63:0]   rsi_start_addr [1:3];     // RSI veri baslangic adresleri (1DEA0001)
    bit          rsi_start_valid = 1'b0;

    // ---- turlar (1DEA0003) ----
    int          t_count = 0;              // yakalanan tur sayisi
    bit [63:0]   t_off      [1:3][0:MAXR-1];   // RSI veri adres offset'i
    int unsigned t_nk       [1:3][0:MAXR-1];   // RSI basina indirilecek huzme sayisi
    bit [31:0]   t_hid      [0:MAXR-1];
    int unsigned t_m        [0:MAXR-1];        // SIFPGA alma huzme sayisi (M)
    int unsigned t_darbe    [0:MAXR-1];
    int unsigned t_ornek    [0:MAXR-1];
    int unsigned t_nsample  [0:MAXR-1];        // N = darbe * ornek
    int          rsi_tur_idx [1:3] = '{0, 0, 0};   // her RSI'nin kapattigi tur sayisi

    function automatic bit tur_var(int tur);
        return (tur >= 0 && tur < t_count);
    endfunction

    // Surucunun (scn_pkg::driver) her TLP icin cagirdigi izleyici. cont=1 ise bolunmus mesajin devam paketidir.
    function automatic void track_cfg_msgs(bit [7:0] pkt[], bit cont);
        bit [63:0] id;
        int        n;
        if (cont || pkt.size() < 24) return;
        id = bytes_to_val(pkt, 16, 4, 1'b0);
        if (id[31:0] == ID_ADRES_ATAMA && pkt.size() >= 24 + 120) begin
            for (int k = 1; k <= NRSI; k++)
                rsi_start_addr[k] = bytes_to_val(pkt, 24 + 96 + 8 * (k - 1), 8, 1'b0);
            rsi_start_valid = 1'b1;
            $display("[RSI] adres atama: RSI1=%h RSI2=%h RSI3=%h", rsi_start_addr[1], rsi_start_addr[2], rsi_start_addr[3]);
        end else if (id[31:0] == ID_SIFPGA_HUZPAR && pkt.size() >= 24 + 39) begin
            if (t_count >= MAXR) begin
                $display("[RSI] UYARI: en fazla %0d tur izlenir, bu 1DEA0003 atlandi", MAXR);
                return;
            end
            n = t_count;
            for (int k = 1; k <= NRSI; k++) begin
                t_off[k][n] = bytes_to_val(pkt, 24 + 8 * (k - 1), 8, 1'b0);
                t_nk[k][n]  = pkt[24 + 35 + k];
            end
            t_hid[n]     = bytes_to_val(pkt, 24 + 24, 4, 1'b0);
            t_m[n]       = bytes_to_val(pkt, 24 + 28, 2, 1'b0);
            t_darbe[n]   = bytes_to_val(pkt, 24 + 30, 2, 1'b0);
            t_ornek[n]   = bytes_to_val(pkt, 24 + 32, 2, 1'b0);
            t_nsample[n] = t_darbe[n] * t_ornek[n];
            t_count      = t_count + 1;
            $display("[RSI] tur #%0d (1DEA0003): huzme_id=%h M=%0d darbe=%0d ornek=%0d N=%0d n_k=%0d/%0d/%0d offset=%h/%h/%h",
                     t_count, t_hid[n], t_m[n], t_darbe[n], t_ornek[n], t_nsample[n], t_nk[1][n], t_nk[2][n], t_nk[3][n],
                     t_off[1][n], t_off[2][n], t_off[3][n]);
        end
    endfunction

    // ---- tur raporu: her RSI kendi turunu raporlar; hepsi raporlayinca birlesim kontrolu yapilir ----
    bit          r_reported [1:3][0:MAXR-1];
    bit          r_basarili [1:3][0:MAXR-1];    // MSI1 ile mi kapandi
    bit          r_dogru    [1:3][0:MAXR-1];    // RSI'nin kendi kontrolleri gecti mi
    int          r_nbeam    [1:3][0:MAXR-1];
    int          r_rule     [1:3][0:MAXR-1];    // birlestirme carpani (0 = taninmadi)
    bit          r_printed  [0:MAXR-1];
    int          r_beamcnt  [0:MAXR-1][0:MAXB-1];   // huzme -> kac RSI'de goruldu
    int          rsi_sum_fd = 0;

    function automatic string rule_name(int k);
        if (k == 3)      return "TOPLAM";
        else if (k == 1) return "SHOB-1";
        else if (k == 2) return "SHOB-2";
        else             return "TANINMADI";
    endfunction

    function automatic void rsi_sum_log(string s);
        if (rsi_sum_fd == 0) begin
            rsi_sum_fd = $fopen("rsi_tur_ozeti.txt", "w");
            if (rsi_sum_fd != 0)
                $fdisplay(rsi_sum_fd, "# RSI tur ozeti (v1.0.7): her satir bir huzme turu; RSI modelleri raporlayinca yazilir");
        end
        if (rsi_sum_fd != 0) begin
            $fdisplay(rsi_sum_fd, "%s", s);
            $fflush(rsi_sum_fd);
        end
    endfunction

    // RSI'nin bu turda gordugu bir huzmeyi kaydeder (rsi_report_round'dan ONCE cagrilir)
    function automatic void rsi_beam_add(int tur, int m);
        if (tur >= 0 && tur < MAXR && m >= 0 && m < MAXB) r_beamcnt[tur][m] = r_beamcnt[tur][m] + 1;
    endfunction

    // RSI 'rsi' kendi 'tur' (0 tabanli) turunu raporlar.
    function automatic void rsi_report_round(int rsi, int tur, bit basarili, bit dogru, int rule_k, int nbeams);
        bit          all_in;
        bit          all_ok;
        int          missing, dup;
        string       line;
        if (tur < 0 || tur >= MAXR) return;
        r_reported[rsi][tur] = 1'b1;
        r_basarili[rsi][tur] = basarili;
        r_dogru[rsi][tur]    = dogru;
        r_rule[rsi][tur]     = rule_k;
        r_nbeam[rsi][tur]    = nbeams;
        // hangi RSI'lerin raporlamasi bekleniyor: n_k > 0 olanlar (yapilandirma yoksa raporlayanlar)
        all_in = 1'b1;
        if (tur_var(tur)) begin
            for (int k = 1; k <= NRSI; k++)
                if (t_nk[k][tur] > 0 && !r_reported[k][tur]) all_in = 1'b0;
        end else begin
            all_in = (r_reported[1][tur] || r_reported[2][tur] || r_reported[3][tur]);
        end
        if (!all_in || r_printed[tur]) return;
        r_printed[tur] = 1'b1;

        all_ok = 1'b1;
        line = $sformatf("TUR %0d", tur + 1);
        if (tur_var(tur))
            line = {line, $sformatf(" huzme_id=%h M=%0d N=%0d", t_hid[tur], t_m[tur], t_nsample[tur])};
        for (int k = 1; k <= NRSI; k++)
            if (r_reported[k][tur]) begin
                line = {line, $sformatf(" | RSI%0d: %0s huzme=%0d %0s", k, r_basarili[k][tur] ? "YAZILDI" : "YAZILAMADI",
                                        r_nbeam[k][tur], r_dogru[k][tur] ? "DOGRU" : "YANLIS")};
                if (!r_basarili[k][tur] || !r_dogru[k][tur]) all_ok = 1'b0;
            end
        rsi_sum_log(line);
        if (all_ok && tur_var(tur)) begin
            // birlesim: 0..M-1 her huzme tam bir kez, RSI'ler arasinda
            missing = 0; dup = 0;
            for (int b = 0; b < t_m[tur] && b < MAXB; b++) begin
                if (r_beamcnt[tur][b] == 0)      missing++;
                else if (r_beamcnt[tur][b] > 1)  dup++;
            end
            rsi_sum_log($sformatf("  birlesim: %0d huzme bekleniyor, eksik=%0d, birden cok RSI'de=%0d, birlesim kurali: RSI1=%0s RSI2=%0s RSI3=%0s -> %0s",
                                  t_m[tur], missing, dup, rule_name(r_rule[1][tur]), rule_name(r_rule[2][tur]), rule_name(r_rule[3][tur]),
                                  (missing == 0 && dup == 0) ? "DOGRU" : "YANLIS"));
        end else if (!all_ok) begin
            rsi_sum_log("  tur sonucu: BASARISIZ ya da YANLIS (ayrintilar rsiN_out.txt dosyalarinda)");
        end
    endfunction

endpackage
