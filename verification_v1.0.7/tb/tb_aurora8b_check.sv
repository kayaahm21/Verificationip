`timescale 1ns / 1ps

// =====================================================================
// tb_aurora8b_check : Aurora 8b10b gozlemci VIP'inin (v1.0.5) kendi kendini kontrol eden testi
//   B1  tx_out_clk 125 MHz (8 ns)
//   B2  link sirasi: gt_powergood -> tx_lock -> sys_reset_out biter -> channel_up/lane_up
//   B3  RX bos
//   B4  kullanici verisi her zaman kabul edilir ve log'a yazilir
//   B7  gelen mesaj (ID+LEN+veri, 32 bit beat'ler, tlast) birlestirilip log'a yazilir: len=0, len=8, len=6 (kismi son beat)
//   B8  HUZPAR: istek 00000001 (M=N=4, LEN=2872, 720 beat) -> 1 us sonra 00000002 cevabi (LEN=24, 8 beat): huzme ID, gclk, 4 x huzme ID
//   B9  diger ID'lere cevap yok; LEN uyusmazligi uyari verir ama cevap yine gelir
//   B5  reset yukselen kenari linki yeniden baslatir; reset SEVIYESI tutulsa da kilitlenme olmaz
// =====================================================================
module tb_aurora8b_check;
    reg  [31:0] tx_tdata = 32'd0;
    reg  [3:0]  tx_tkeep = 4'd0;
    reg         tx_tlast = 1'b0, tx_tvalid = 1'b0;
    wire        tx_tready;
    reg         reset = 1'b0, gt_reset = 1'b0;
    reg         refclk = 1'b0;
    always #2 refclk = ~refclk;

    wire [31:0] rx_tdata;
    wire [3:0]  rx_tkeep;
    wire        rx_tlast;
    wire        clk, channel_up, sys_reset, tx_lock, link_reset, rx_valid;
    wire [0:0]  lane_up, powergood;

    aurora_8b10b_vip #(.UNIT_NAME("tb"), .LINK_UP_CLKS(625)) dut (
        .s_axi_tx_tdata(tx_tdata), .s_axi_tx_tkeep(tx_tkeep), .s_axi_tx_tvalid(tx_tvalid),
        .s_axi_tx_tlast(tx_tlast), .s_axi_tx_tready(tx_tready),
        .m_axi_rx_tdata(rx_tdata), .m_axi_rx_tkeep(rx_tkeep), .m_axi_rx_tvalid(rx_valid), .m_axi_rx_tlast(rx_tlast),
        .rxp(1'b0), .rxn(1'b1), .txp(), .txn(), .gt_refclk1(refclk),
        .frame_err(), .hard_err(), .soft_err(), .lane_up(lane_up), .channel_up(channel_up),
        .crc_pass_fail_n(), .crc_valid(),
        .user_clk(clk), .sync_clk(clk), .gt_reset(gt_reset), .reset(reset),
        .sys_reset_out(sys_reset), .power_down(1'b0), .loopback(3'b000), .tx_lock(tx_lock),
        .init_clk_in(refclk), .tx_resetdone_out(), .rx_resetdone_out(), .link_reset_out(link_reset),
        .gt_powergood(powergood), .tx_out_clk(clk), .bufg_gt_clr_out(), .pll_not_locked(1'b0)
    );

    integer errors = 0;
    task chk(input cond, input [8*64-1:0] msg);
        if (!cond) begin $display("[TB] HATA: %0s", msg); errors = errors + 1; end
        else       $display("[TB] tamam: %0s", msg);
    endtask


    // ---- v1.0.5: mesaj beat'i gonder (negedge'de surulur, DUT posedge'de ornekler) ----
    task send_beat(input [31:0] d, input [3:0] k, input last);
        begin
            @(negedge clk);
            tx_tdata <= d; tx_tkeep <= k; tx_tlast <= last; tx_tvalid <= 1'b1;
        end
    endtask
    task end_msg;
        begin
            @(negedge clk);
            tx_tvalid <= 1'b0; tx_tlast <= 1'b0; tx_tkeep <= 4'h0;
            repeat (2) @(negedge clk);
        end
    endtask


    // ---- v1.0.5: RX cevap yakalama (negedge'de ornekle: tvalid tam bir clock yuksek kalir) ----
    reg [31:0] rxw [0:63];
    integer    rx_n = 0;
    realtime   rx_first_t = 0, req_end_t = 0;
    integer    rx_badkeep = 0, rx_badlast = 0, rx_lastcnt = 0;
    always @(negedge clk) begin
        if (rx_valid) begin
            if (rx_n == 0) rx_first_t = $realtime;
            rxw[rx_n] = rx_tdata;
            rx_n = rx_n + 1;
            if (rx_tkeep !== 4'hF) rx_badkeep = rx_badkeep + 1;
            if (rx_tlast)          rx_lastcnt = rx_lastcnt + 1;
        end
    end

    realtime t0, t1;
    initial begin
        @(posedge clk); t0 = $realtime;
        @(posedge clk); t1 = $realtime;
        chk((t1 - t0) == 8.0, "B1 tx_out_clk periyodu 8 ns (125 MHz)");

        chk(!channel_up && sys_reset, "B2 baslangicta channel_up=0, sys_reset aktif");
        wait (powergood == 1'b1);
        wait (tx_lock);
        wait (!sys_reset);
        chk(!channel_up, "B2 sys_reset bittiginde channel_up henuz 0");
        wait (channel_up);
        chk(lane_up == 1'b1 && !link_reset, "B2 channel_up: lane_up=1, link_reset_out=0");

        chk(!rx_valid, "B3 RX bos");

        @(negedge clk);
        tx_tdata <= 32'hCAFEF00D; tx_tkeep <= 4'hF; tx_tlast <= 1'b1; tx_tvalid <= 1'b1;
        #1;
        chk(tx_tready, "B4 s_axi_tx_tready=1");
        @(negedge clk);
        tx_tvalid <= 1'b0; tx_tlast <= 1'b0;
        repeat (3) @(posedge clk);

        // B4: kisa mesaj (tek beat, 4 bayt): ID+LEN'e yetmez -> MSG_KISA uyarisi
        // B7: tam mesajlar
        // (a) CIT istegi: 0000E003, len=0
        send_beat(32'h0000E003, 4'hF, 1'b0);
        send_beat(32'h00000000, 4'hF, 1'b1);
        end_msg;
        // (b) len=8: 4 beat
        send_beat(32'h00001234, 4'hF, 1'b0);
        send_beat(32'h00000008, 4'hF, 1'b0);
        send_beat(32'h44332211, 4'hF, 1'b0);
        send_beat(32'h88776655, 4'hF, 1'b1);
        end_msg;
        // (c) len=6: son beat kismi (tkeep=0011)
        send_beat(32'h0000ABCD, 4'hF, 1'b0);
        send_beat(32'h00000006, 4'hF, 1'b0);
        send_beat(32'hA4A3A2A1, 4'hF, 1'b0);
        send_beat(32'h0000A6A5, 4'h3, 1'b1);
        end_msg;
        // (d) len uyusmazligi: len=8 denmis ama 4 bayt gelmis
        send_beat(32'h00005678, 4'hF, 1'b0);
        send_beat(32'h00000008, 4'hF, 1'b0);
        send_beat(32'hDDCCBBAA, 4'hF, 1'b1);
        end_msg;

        // B8/B9: onceki mesajlara (ID 0000E003, 00001234, 0000ABCD, 00005678) cevap verilmemis olmali
        chk(rx_n == 0, "B9 HUZPAR disindaki mesaj ID'lerine cevap yok");

        // B8: HUZPAR istegi: ID 00000001, LEN=2872 (M=N=4, F=0): huzme ID + 28 + 8 + 4 x 708 bayt
        begin : huzpar_test
            integer k, ok_first;
            reg [31:0] lf, hz;
            hz = 32'h12345678;
            lf = 32'hACE1;
            send_beat(32'h00000001, 4'hF, 1'b0);          // ID
            send_beat(32'd2872,     4'hF, 1'b0);          // LEN (yalniz veri)
            send_beat(hz,           4'hF, 1'b0);          // veri[0..3] = huzme ID
            for (k = 1; k < 718; k = k + 1) begin         // kalan 2868 bayt = 717 kelime (rastgele)
                lf = lf * 32'd1664525 + 32'd1013904223;
                send_beat(lf, 4'hF, (k == 717));
            end
            req_end_t = $realtime;
            end_msg;
            wait (rx_n >= 8);
            repeat (6) @(negedge clk);
            chk(rx_n == 8, "B8 cevap 8 beat (32 bayt)");
            chk(rxw[0] == 32'h00000002, "B8 kelime0 = 00000002 (cevap mesaj ID)");
            chk(rxw[1] == 32'd24, "B8 kelime1 = 24 (LEN = 4*M + 8)");
            chk(rxw[2] == hz, "B8 huzme ID istekten aynen geri yansitildi");
            chk(rxw[3] != 32'd0, "B8 huzme basi zamani (gclk) sayac degeri, sifir degil");
            chk(rxw[4] == hz && rxw[5] == hz && rxw[6] == hz && rxw[7] == hz, "B8 4 ADK cevabi = huzme ID");
            chk((rx_first_t - req_end_t) >= 1000.0 && (rx_first_t - req_end_t) < 1100.0, "B8 cevap istekten ~1 us sonra");
            chk(rx_badkeep == 0, "B8 her beat: tkeep=0xF");
            chk(rx_lastcnt == 1, "B8 tlast yalnizca son beat'te (bir kez)");
        end

        // B9: LEN uyusmazligi: ID 00000001, LEN=8 (veri: huzme ID + 4 bayt) -> uyari + cevap yine gelir
        rx_n = 0; rx_lastcnt = 0;
        send_beat(32'h00000001, 4'hF, 1'b0);
        send_beat(32'h00000008, 4'hF, 1'b0);
        send_beat(32'h0000BEEF, 4'hF, 1'b0);
        send_beat(32'h00000000, 4'hF, 1'b1);
        end_msg;
        wait (rx_n >= 8);
        repeat (6) @(negedge clk);
        chk(rx_n == 8 && rxw[2] == 32'h0000BEEF && rxw[0] == 32'h00000002, "B9 uyusmayan LEN'de de cevap geldi (huzme ID = 0000BEEF)");

        // B5: reset darbesi linki dusurur; seviyesi tutulsa bile sayac ilerler
        @(negedge clk);
        reset <= 1'b1;
        repeat (3) @(posedge clk);
        chk(!channel_up && sys_reset, "B5 reset kenari: channel_up=0, sys_reset aktif");
        wait (channel_up);   // reset hala yuksek, yine de link kurulmali (kilitlenme yok)
        chk(channel_up, "B5 reset yuksek tutulsa da kilitlenme yok, link kuruldu");
        reset <= 1'b0;

        #100;
        check_log;
        if (errors == 0) $display("[TB] *** TUM TESTLER GECTI ***");
        else             $display("[TB] *** %0d HATA ***", errors);
        $finish;
    end

    task check_log;
        integer fd, code;
        string  line;
        bit got_user = 0, got_link = 0, got_short = 0, got_m0 = 0, got_m8 = 0, got_m6 = 0, got_warn = 0, got_hz = 0, got_hzplan = 0, got_hzdone = 0, got_hzwarn = 0;
        begin
            fd = $fopen("aurora8b10b_obs_tb.txt", "r");
            chk(fd != 0, "B6 log dosyasi acildi");
            while (fd != 0 && !$feof(fd)) begin
                line = "";
                code = $fgets(line, fd);
                if (code == 0) break;
                if (has(line, "USER_TX data=cafef00d keep=f last=1")) got_user = 1;
                if (has(line, "LINK channel_up=1 lane_up=1")) got_link = 1;
                if (has(line, "MSG_KISA bayt=4")) got_short = 1;
                if (has(line, "MSG id=0000e003 len=0 data=")) got_m0 = 1;
                if (has(line, "MSG id=00001234 len=8 data=11 22 33 44 55 66 77 88")) got_m8 = 1;
                if (has(line, "MSG id=0000abcd len=6 data=a1 a2 a3 a4 a5 a6")) got_m6 = 1;
                if (has(line, "MSG_UYARI len=8 ama 4 veri bayti geldi")) got_warn = 1;
                if (has(line, "MSG id=00000001 len=2872 data=") && has(line, "... (toplam 2872 veri bayti)")) got_hz = 1;
                if (has(line, "HUZPAR_CEVAP planlandi id=00000002 len=24 huzme_id=12345678")) got_hzplan = 1;
                if (has(line, "HUZPAR_CEVAP bitti id=00000002")) got_hzdone = 1;
                if (has(line, "MSG_UYARI HUZPAR len=8, beklenen 2872 (M=4 N=4 F=0)")) got_hzwarn = 1;
            end
            if (fd != 0) $fclose(fd);
            chk(got_user, "B6 log: USER_TX");
            chk(got_link, "B6 log: LINK channel_up=1");
            chk(got_short, "B7 log: tek beat'lik kisa mesaj icin MSG_KISA");
            chk(got_m0, "B7 log: MSG id=0000e003 len=0");
            chk(got_m8, "B7 log: MSG id=00001234 len=8 + 8 bayt veri");
            chk(got_m6, "B7 log: MSG id=0000abcd len=6 + 6 bayt (kismi son beat)");
            chk(got_warn, "B7 log: len uyusmazligi icin MSG_UYARI");
            chk(got_hz, "B8 log: MSG id=00000001 len=2872 (veri kisaltildi)");
            chk(got_hzplan && got_hzdone, "B8 log: HUZPAR_CEVAP planlandi/bitti");
            chk(got_hzwarn, "B9 log: HUZPAR beklenen LEN uyarisi");
        end
    endtask

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
