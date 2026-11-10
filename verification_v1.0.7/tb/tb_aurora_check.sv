`timescale 1ns / 1ps

// =====================================================================
// tb_aurora_check : Aurora gozlemci VIP'inin (v1.0.5) kendi kendini kontrol eden testi
//
// Tasarim (FPGA) rolunu taklit eder:
//   A1  user_clk_out 125 MHz (8 ns periyot)
//   A2  reset/link sirasi: gt_powergood -> gt_pll_lock -> sys_reset_out biter -> channel_up/lane_up
//   A3  RX arayuzleri bos (cevap uretilmez)
//   A4  UFC TX: ufc_tx_req + ms=3 -> s_axi_ufc_tx_tready gelir; veri beat'i kabul edilir
//   A5  kullanici verisi her zaman kabul edilir; log'a alt 128 bit yazilir
//   C1  0000E003 (len=0) istegine 1 us sonra 0000E004 (len=184) cevabi: 48 UFC kelimesi, alan duzeni
//   C2  diger mesaj ID'lerine cevap verilmez
//   D1  SHOB HUZPAR ve KATSAYILAR (0000E001): 16 baytlik beat'ler (alt 128 bit, ust 64 bit tkeep=0) birlestirilir,
//       alanlar aurora_huzpar_tb.txt'ye, katsayilar aurora_huzpar_katsayi_tb.txt'ye yazilir; hatali mesaj uyari uretir
//   A6  reset_pb ile link yeniden kurulur
//   A7  log dosyasi beklenen satirlari icerir
// =====================================================================
module tb_aurora_check;
    reg  [191:0] tx_tdata = 192'd0;
    reg  [23:0]  tx_tkeep = 24'd0;
    reg          tx_tlast = 1'b0, tx_tvalid = 1'b0;
    wire         tx_tready;
    reg          ufc_req = 1'b0;
    reg  [7:0]   ufc_ms  = 8'd3;
    reg  [191:0] ufc_tdata = 192'd0;
    reg          ufc_tvalid = 1'b0;
    wire         ufc_tready;
    reg          reset_pb = 1'b0, pma_init = 1'b0;
    reg          refclk = 1'b0;
    always #2 refclk = ~refclk;     // 250 MHz referans

    wire         user_clk, channel_up, sys_reset, gt_reset, pll_lock, link_reset;
    wire [0:2]   lane_up;
    wire [2:0]   powergood;
    wire         rx_valid, ufc_rx_valid, ufc_inprog, refclk_out;
    wire [191:0] ufc_rx_tdata;
    wire [23:0]  ufc_rx_tkeep;
    wire         ufc_rx_tlast;

    aurora_64b66b_vip #(.UNIT_NAME("tb"), .LINK_UP_CLKS(625)) dut (
        .s_axi_tx_tdata(tx_tdata), .s_axi_tx_tlast(tx_tlast), .s_axi_tx_tkeep(tx_tkeep),
        .s_axi_tx_tvalid(tx_tvalid), .s_axi_tx_tready(tx_tready),
        .m_axi_rx_tdata(), .m_axi_rx_tlast(), .m_axi_rx_tkeep(), .m_axi_rx_tvalid(rx_valid),
        .ufc_tx_req(ufc_req), .ufc_tx_ms(ufc_ms), .s_axi_ufc_tx_tdata(ufc_tdata),
        .s_axi_ufc_tx_tvalid(ufc_tvalid), .s_axi_ufc_tx_tready(ufc_tready),
        .m_axi_ufc_rx_tdata(ufc_rx_tdata), .m_axi_ufc_rx_tkeep(ufc_rx_tkeep), .m_axi_ufc_rx_tlast(ufc_rx_tlast),
        .m_axi_ufc_rx_tvalid(ufc_rx_valid), .ufc_in_progress(ufc_inprog),
        .rxp(3'b000), .rxn(3'b111), .txp(), .txn(),
        .gt_refclk1_p(refclk), .gt_refclk1_n(~refclk), .gt_refclk1_out(refclk_out),
        .hard_err(), .soft_err(), .channel_up(channel_up), .lane_up(lane_up),
        .crc_pass_fail_n(), .crc_valid(),
        .user_clk_out(user_clk), .mmcm_not_locked_out(), .sync_clk_out(),
        .reset_pb(reset_pb), .gt_rxcdrovrden_in(1'b0), .power_down(1'b0), .loopback(3'b000),
        .pma_init(pma_init), .gt_pll_lock(pll_lock),
        .init_clk(refclk), .link_reset_out(link_reset), .gt_powergood(powergood),
        .sys_reset_out(sys_reset), .gt_reset_out(gt_reset), .tx_out_clk()
    );

    integer errors = 0;
    task chk(input cond, input [8*64-1:0] msg);
        if (!cond) begin $display("[TB] HATA: %0s", msg); errors = errors + 1; end
        else       $display("[TB] tamam: %0s", msg);
    endtask


    // ---- v1.0.5: UFC kelime gonderme + cevap yakalama ----
    // Surucu negedge'de surulur (DUT posedge'de ornekler); her kelime ayri 4 baytlik UFC mesaji (ms=3)
    task send_ufc_word(input [31:0] w);
        begin
            @(negedge user_clk);
            ufc_req <= 1'b1; ufc_ms <= 8'd3;
            @(negedge user_clk);
            ufc_req <= 1'b0; ufc_tdata <= {160'd0, w}; ufc_tvalid <= 1'b1;
            @(negedge user_clk);
            ufc_tvalid <= 1'b0;
            @(negedge user_clk);
        end
    endtask

    reg [31:0] rxw [0:127];
    integer    rx_n = 0;
    realtime   rx_first_t = 0, req_end_t = 0;
    integer    rx_badkeep = 0, rx_badlast = 0, rx_badip = 0;
    // negedge'de ornekle: tvalid tam bir clock yuksek kalir, bir kez gorulur
    always @(negedge user_clk) begin
        if (ufc_rx_valid) begin
            if (rx_n == 0) rx_first_t = $realtime;
            rxw[rx_n] = ufc_rx_tdata[31:0];
            rx_n = rx_n + 1;
            if (ufc_rx_tkeep !== 24'h00000F) rx_badkeep = rx_badkeep + 1;
            if (ufc_rx_tlast !== 1'b1)       rx_badlast = rx_badlast + 1;
            if (ufc_inprog   !== 1'b0)       rx_badip   = rx_badip + 1;   // islemde = 0 (active-low)
        end
    end

    // cevap bayt'larini kelimelerden (little-endian) geri cozer
    function [7:0] rbyte(input integer i);   // i: veri bayt indeksi 0..183
        reg [31:0] w;
        begin
            w = rxw[2 + i/4];
            rbyte = w >> (8 * (i % 4));
        end
    endfunction
    function [15:0] r16(input integer i);
        r16 = {rbyte(i+1), rbyte(i)};
    endfunction
    function [31:0] r32(input integer i);
        r32 = {rbyte(i+3), rbyte(i+2), rbyte(i+1), rbyte(i)};
    endfunction


    // ---- v1.0.5: HUZPAR mesaj ureticisi (16 baytlik beat'ler) ----
    reg [7:0] tb_m [0:16383];
    integer   tb_n = 0;
    task put8(input [7:0] v);   begin tb_m[tb_n] = v; tb_n = tb_n + 1; end endtask
    task put16(input [15:0] v); begin put8(v[7:0]); put8(v[15:8]); end endtask
    task put32(input [31:0] v); begin put16(v[15:0]); put16(v[31:16]); end endtask
    // tb_m[] icindeki mesaji 16 baytlik beat'lerle gonder (alt 128 bit, tkeep[15:0]; ust 64 bit tkeep=0)
    task send_msg16;
        integer i, j, rem;
        reg [127:0] d;
        reg [23:0]  kp;
        begin
            for (i = 0; i < tb_n; i = i + 16) begin
                rem = tb_n - i;
                d = 128'd0; kp = 24'd0;
                for (j = 0; j < 16; j = j + 1)
                    if (j < rem) begin d[8*j +: 8] = tb_m[i + j]; kp[j] = 1'b1; end
                @(negedge user_clk);
                tx_tdata <= {64'd0, d}; tx_tkeep <= kp; tx_tlast <= (rem <= 16); tx_tvalid <= 1'b1;
            end
            @(negedge user_clk);
            tx_tvalid <= 1'b0; tx_tlast <= 1'b0; tx_tkeep <= 24'd0;
            repeat (3) @(negedge user_clk);
            tb_n = 0;
        end
    endtask
    // 56 baytlik HUZPAR basligi (ID+LEN dahil degil): huzme id, durum, M, darbe, ornek, 4 maske, kart, test, 22 reserved
    task put_huzpar_header(input [31:0] hid, input [15:0] durum, input [15:0] nb, input [31:0] darbe, input [31:0] ornek,
                           input [31:0] m0, input [31:0] m1, input [31:0] m2, input [31:0] m3, input [7:0] kart, input [7:0] test);
        integer r;
        begin
            put32(hid); put16(durum); put16(nb); put32(darbe); put32(ornek);
            put32(m0); put32(m1); put32(m2); put32(m3);
            put8(kart); put8(test);
            for (r = 0; r < 22; r = r + 1) put8(8'h00);
        end
    endtask

    // ---- A1: saat periyodu ----
    realtime t0, t1;
    initial begin
        // A1
        @(posedge user_clk); t0 = $realtime;
        @(posedge user_clk); t1 = $realtime;
        chk((t1 - t0) == 8.0, "A1 user_clk_out periyodu 8 ns (125 MHz)");

        // A2
        chk(!channel_up && sys_reset && gt_reset, "A2 reset sirasinda channel_up=0, resetler aktif");
        wait (powergood == 3'b111);
        wait (pll_lock);
        wait (!gt_reset);
        chk(sys_reset, "A2 gt_reset bittiginde sys_reset hala aktif");
        wait (!sys_reset);
        chk(!channel_up, "A2 sys_reset bittiginde channel_up henuz 0");
        wait (channel_up);
        chk(lane_up == 3'b111 && !link_reset, "A2 channel_up: lane_up=111, link_reset_out=0");
        chk(refclk_out === refclk, "gt_refclk1_out = gt_refclk1_p");

        // A3
        chk(!rx_valid && !ufc_rx_valid && ufc_inprog === 1'b1, "A3 RX bos, ufc_in_progress bosta seviyesinde (1, active-low)");

        // A4: UFC TX. Surucu negedge'de surulur, DUT posedge'de ornekler (simulator yaris kosullarindan bagimsiz).
        @(negedge user_clk);
        chk(!ufc_tready, "A4 istek yokken ufc tready=0");
        ufc_req <= 1'b1; ufc_ms <= 8'd3;
        @(negedge user_clk);            // arada bir posedge: DUT istegi gordu, busy=1
        ufc_req    <= 1'b0;
        ufc_tdata  <= {160'd0, 32'hCAFEF00D};
        ufc_tvalid <= 1'b1;
        #1;
        chk(ufc_tready, "A4 ufc_tx_req sonrasi s_axi_ufc_tx_tready geldi (tvalid=1 iken)");
        @(negedge user_clk);            // arada bir posedge: el sikismasi tamamlandi
        ufc_tvalid <= 1'b0;
        #1;
        chk(!ufc_tready, "A4 tek beat'ten sonra tready=0");

        // A4 tek kelime (ID=cafef00d) yolladi; mesaj birlestirici icin LEN kelimesiyle (0) mesaji tamamla
        send_ufc_word(32'h00000000);

        // A5: kullanici verisi, ust 64 bit dolu ama log alt 128 biti yazar
        @(posedge user_clk);
        tx_tdata  <= {64'hDEADDEADDEADDEAD, 128'h00112233445566778899AABBCCDDEEFF};
        tx_tkeep  <= 24'h00FFFF;
        tx_tlast  <= 1'b1;
        tx_tvalid <= 1'b1;
        @(posedge user_clk);
        chk(tx_tready, "A5 s_axi_tx_tready=1");
        tx_tvalid <= 1'b0; tx_tlast <= 1'b0;
        repeat (3) @(posedge user_clk);


        // C1: CIT istegi (0000E003, len=0) -> iki UFC mesaji: ID, LEN
        send_ufc_word(32'h0000E003);
        send_ufc_word(32'h00000000);
        req_end_t = $realtime;
        wait (rx_n >= 48);
        repeat (6) @(negedge user_clk);
        chk(rx_n == 48, "C1 cevap 48 UFC kelimesi");
        chk(rxw[0] == 32'h0000E004, "C1 kelime0 = 0000E004 (mesaj ID)");
        chk(rxw[1] == 32'd184, "C1 kelime1 = 184 (LEN)");
        chk((rx_first_t - req_end_t) >= 1000.0 && (rx_first_t - req_end_t) < 1100.0, "C1 cevap istekten ~1 us sonra");
        chk(rx_badkeep == 0 && rx_badlast == 0, "C1 her kelime: tkeep=0xF, tlast=1");
        chk(rx_badip == 0, "C1 cevap beat'inde ufc_in_progress islemde seviyesinde (0)");
        chk(ufc_inprog === 1'b1, "C1 cevap sonrasi ufc_in_progress bosta (1)");
        begin : cit_check
            integer k, j, ok_zero, ok_temp, ok_vi, ok_res;
            reg [31:0] tm;
            ok_zero = 1; ok_temp = 1; ok_vi = 1; ok_res = 1;
            for (k = 0; k < 4; k = k + 1) begin
                for (j = 0; j < 8; j = j + 1)  if (rbyte(46*k + j) !== 8'h00) ok_zero = 0;
                for (j = 0; j < 14; j = j + 1) if ($signed(rbyte(46*k + 8 + j)) < 20 || $signed(rbyte(46*k + 8 + j)) > 60) ok_temp = 0;
                // [0]: akim 1000..3000 mA, [1..7]: gerilim 900..13000 mV
                if (r16(46*k + 26) < 1000 || r16(46*k + 26) > 3000) ok_vi = 0;
                for (j = 1; j < 8; j = j + 1)
                    if (r16(46*k + 26 + 2*j) < 900 || r16(46*k + 26 + 2*j) > 13000) ok_vi = 0;
                for (j = 0; j < 4; j = j + 1)  if (rbyte(46*k + 42 + j) !== 8'h00) ok_res = 0;
            end
            chk(ok_zero, "C1 her blok: ilk 8 bayt 0");
            chk(ok_temp, "C1 14 sicaklik gercekci aralikta (int8, 20..60 C)");
            chk(ok_vi, "C1 8 x uint16: akim ve gerilimler gercekci aralikta");
            chk(ok_res, "C1 her blok: son 4 bayt reserved = 0");
            tm = r32(22);
            chk(tm >= 273600 && tm < 273700, "C1 cihaz saati (uint32, saniye) = ofset + sim suresi");
            chk(r32(46 + 22) == tm && r32(92 + 22) == tm && r32(138 + 22) == tm, "C1 dort blokta saat ayni");
            chk(r16(26) == 1250 && r16(46 + 26) == 1400 && r16(92 + 26) == 1550 && r16(138 + 26) == 1700, "C1 akimlar blok basina 1250 + 150*k mA");
            chk(r16(28) == 12000 && r16(30) == 5000 && r16(138 + 28) == 11985, "C1 gerilim ornekleri (12000, 5000 mV; blok3: 11985)");
        end

        // C2: tanimsiz mesaj ID'sine (0000E005, len=0) cevap verilmez
        rx_n = 0;
        send_ufc_word(32'h0000E005);
        send_ufc_word(32'h00000000);
        repeat (400) @(negedge user_clk);
        chk(rx_n == 0, "C2 tanimsiz mesaj ID'sine cevap yok");


        // D1: SHOB HUZPAR ve KATSAYILAR. (1) gecerli HO mesaji, M=4, darbe=4, ornek=4; katsayi I = h*1000+g*10+k, Q = -I
        begin : d1_test
            integer h, g, k;
            reg signed [15:0] cv;
            put32(32'h0000E001); put32(32'd7736);
            put_huzpar_header(32'h0000AB12, 16'd1, 16'd4, 32'd4, 32'd4, 32'h3FFFFFFF, 32'h00000001, 32'h20000000, 32'h15555555, 8'h01, 8'h00);
            for (h = 1; h <= 4; h = h + 1)
                for (g = 1; g <= 120; g = g + 1)
                    for (k = 1; k <= 4; k = k + 1) begin
                        cv = h * 1000 + g * 10 + k;
                        put16(cv);          // I
                        put16(-cv);         // Q
                    end
            chk(tb_n == 7744, "D1 mesaj 7744 bayt (8 baslik + 56 + 4x1920)");
            send_msg16;
        end
        // (2) gecerli Bypass: LEN=56, katsayi yok, alma huzmesi sayisi 960
        put32(32'h0000E001); put32(32'd56);
        put_huzpar_header(32'h0000CD34, 16'd0, 16'd960, 32'd4, 32'd4, 32'h3FFFFFFF, 32'h3FFFFFFF, 32'h3FFFFFFF, 32'h3FFFFFFF, 8'h01, 8'h00);
        send_msg16;
        // (3) hatali HO: M=6 (4'un kati degil), LEN=56 (katsayi yok), darbe=0
        put32(32'h0000E001); put32(32'd56);
        put_huzpar_header(32'h0000EF56, 16'd1, 16'd6, 32'd0, 32'd4, 32'h3FFFFFFF, 32'h0, 32'h0, 32'h0, 8'h01, 8'h00);
        send_msg16;
        // (4) baska ID (0000E002): HUZPAR dosyasina girmez, yalniz obs'ta MSG
        put32(32'h0000E002); put32(32'd8); put32(32'h11111111); put32(32'h22222222);
        send_msg16;
        #200;

        begin : d1_check
            integer nh, nu, nk;
            nh = count_in("aurora_huzpar_tb.txt", "HUZPAR id=");
            nu = count_in("aurora_huzpar_tb.txt", "HUZPAR_UYARI");
            nk = count_in("aurora_huzpar_katsayi_tb.txt", "huzme=");
            chk(nh == 3, "D1 huzpar dosyasinda 3 mesaj (E002 girmez)");
            chk(count_in("aurora_huzpar_tb.txt", "HUZPAR id=0000e001 len=7736 huzme_id=0000ab12 durum=HO alma_huzme=4 darbe=4 ornek=4 gac_maske=3fffffff,00000001,20000000,15555555 kart=01 test_modu=0 katsayi_int16=3840") == 1,
                "D1 HO mesaji: alanlar dogru cozuldu");
            chk(count_in("aurora_huzpar_tb.txt", "HUZPAR id=0000e001 len=56 huzme_id=0000cd34 durum=Bypass alma_huzme=960 darbe=4 ornek=4") == 1,
                "D1 Bypass mesaji: alanlar dogru");
            chk(count_in("aurora_huzpar_tb.txt", "huzme_id=0000ef56 durum=HO alma_huzme=6 darbe=0") == 1, "D1 hatali mesaj da cozuldu");
            chk(nu == 3, "D1 yalniz hatali mesaj uyari uretti (3 uyari)");
            chk(count_in("aurora_huzpar_tb.txt", "HO'da alma huzmesi sayisi 4..96 (4'er adim) olmali: 6") == 1, "D1 uyari: M=6 gecersiz");
            chk(count_in("aurora_huzpar_tb.txt", "len=56, beklenen 11576") == 1, "D1 uyari: LEN beklenenden farkli (11576)");
            chk(count_in("aurora_huzpar_tb.txt", "darbe sayisi 0") == 1, "D1 uyari: darbe sayisi 0");
            chk(nk == 480, "D1 katsayi dosyasi 480 satir (4 huzme x 120 GAC)");
            chk(count_in("aurora_huzpar_katsayi_tb.txt", "huzme=1 gac=1 k1 I=1011 Q=-1011") == 1, "D1 katsayi: huzme1 gac1 k1");
            chk(count_in("aurora_huzpar_katsayi_tb.txt", "huzme=2 gac=57 k1 I=2571 Q=-2571 k2 I=2572 Q=-2572 k3 I=2573 Q=-2573 k4 I=2574 Q=-2574") == 1, "D1 katsayi: huzme2 gac57, 4 kanal (negatif Q)");
            chk(count_in("aurora_huzpar_katsayi_tb.txt", "huzme=4 gac=120 k1 I=5201 Q=-5201 k2 I=5202 Q=-5202 k3 I=5203 Q=-5203 k4 I=5204 Q=-5204") == 1, "D1 katsayi: huzme4 gac120 (son satir)");
            chk(count_in("aurora_obs_tb.txt", "MSG id=0000e001 len=7736 data=") == 1 &&
                count_in("aurora_obs_tb.txt", "... (toplam 7736 veri bayti)") == 1, "D1 obs: MSG satiri (veri kisaltildi)");
            chk(count_in("aurora_obs_tb.txt", "MSG id=0000e002 len=8 data=11 11 11 11 22 22 22 22") == 1, "D1 obs: 0000E002 yalniz MSG");
        end

        // A6: reset_pb link'i dusurur, birakinca yeniden kurar
        reset_pb <= 1'b1;
        repeat (3) @(posedge user_clk);
        chk(!channel_up && sys_reset, "A6 reset_pb ile channel_up=0, sys_reset aktif");
        reset_pb <= 1'b0;
        wait (channel_up);
        chk(channel_up, "A6 reset_pb birakilinca link yeniden kuruldu");

        #100;
        check_log;

        if (errors == 0) $display("[TB] *** TUM TESTLER GECTI ***");
        else             $display("[TB] *** %0d HATA ***", errors);
        $finish;
    end

    // ---- A7: log dosyasi icerigi (SystemVerilog string ile) ----
    task check_log;
        integer fd, code;
        string  line;
        bit got_req = 0, got_ufc = 0, got_user = 0, got_link = 0, got_idle = 1, got_plan = 0, got_done = 0, got_msg = 0;
        begin
            fd = $fopen("aurora_obs_tb.txt", "r");
            chk(fd != 0, "A7 log dosyasi acildi");
            while (fd != 0 && !$feof(fd)) begin
                line = "";
                code = $fgets(line, fd);
                if (code == 0) break;
                if (has(line, "UFC_REQ ms=3 (4 bayt)")) got_req = 1;
                if (has(line, "UFC_TX tdata=") && has(line, "cafef00d")) got_ufc = 1;
                if (has(line, "USER_TX lo128=00112233445566778899aabbccddeeff keep=00ffff last=1")) got_user = 1;
                if (has(line, "LINK channel_up=1 lane_up=111")) got_link = 1;
                if (has(line, "UFC_MSG id=0000e003 len=0")) got_msg = 1;
                if (has(line, "UFC_RESP planlandi id=0000e004 len=184")) got_plan = 1;
                if (has(line, "UFC_RESP bitti")) got_done = 1;
                if (has(line, "deadbeef") || has(line, "dead")) got_idle = 0;   // ust 64 bit log'a girmemeli
            end
            if (fd != 0) $fclose(fd);
            chk(got_req,  "A7 log: UFC_REQ ms=3 (4 bayt)");
            chk(got_ufc,  "A7 log: UFC_TX ham veri");
            chk(got_user, "A7 log: USER_TX alt 128 bit");
            chk(got_link, "A7 log: LINK channel_up=1");
            chk(got_idle, "A7 log: ust 64 bit yazilmadi");
            chk(got_msg && got_plan && got_done, "A7 log: UFC_MSG, UFC_RESP planlandi/bitti");
        end
    endtask


    // dosyada alt metin iceren satir sayisi
    function automatic integer count_in(input string fname, input string sub);
        integer fd, code, n;
        string  line;
        begin
            n = 0;
            fd = $fopen(fname, "r");
            while (fd != 0 && !$feof(fd)) begin
                line = "";
                code = $fgets(line, fd);
                if (code == 0) break;
                if (has(line, sub)) n = n + 1;
            end
            if (fd != 0) $fclose(fd);
            count_in = n;
        end
    endfunction

    function automatic bit has(string s, string sub);
        for (int i = 0; i + sub.len() <= s.len(); i++)
            if (s.substr(i, i + sub.len() - 1) == sub) return 1'b1;
        return 1'b0;
    endfunction

    initial begin
        #200000;
        $display("[TB] HATA: zaman asimi");
        $finish;
    end
endmodule
