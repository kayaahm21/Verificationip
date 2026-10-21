`timescale 1ns / 1ps

// =====================================================================
// tb_aurora_check : Aurora gozlemci VIP'inin (v1.0.4) kendi kendini kontrol eden testi
//
// Tasarim (FPGA) rolunu taklit eder:
//   A1  user_clk_out 125 MHz (8 ns periyot)
//   A2  reset/link sirasi: gt_powergood -> gt_pll_lock -> sys_reset_out biter -> channel_up/lane_up
//   A3  RX arayuzleri bos (cevap uretilmez)
//   A4  UFC TX: ufc_tx_req + ms=3 -> s_axi_ufc_tx_tready gelir; veri beat'i kabul edilir
//   A5  kullanici verisi her zaman kabul edilir; log'a alt 128 bit yazilir
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

    aurora_64b66b_vip #(.UNIT_NAME("tb"), .LINK_UP_CLKS(625)) dut (
        .s_axi_tx_tdata(tx_tdata), .s_axi_tx_tlast(tx_tlast), .s_axi_tx_tkeep(tx_tkeep),
        .s_axi_tx_tvalid(tx_tvalid), .s_axi_tx_tready(tx_tready),
        .m_axi_rx_tdata(), .m_axi_rx_tlast(), .m_axi_rx_tkeep(), .m_axi_rx_tvalid(rx_valid),
        .ufc_tx_req(ufc_req), .ufc_tx_ms(ufc_ms), .s_axi_ufc_tx_tdata(ufc_tdata),
        .s_axi_ufc_tx_tvalid(ufc_tvalid), .s_axi_ufc_tx_tready(ufc_tready),
        .m_axi_ufc_rx_tdata(), .m_axi_ufc_rx_tkeep(), .m_axi_ufc_rx_tlast(),
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
        chk(!rx_valid && !ufc_rx_valid && !ufc_inprog, "A3 RX arayuzleri bos (cevap yok)");

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
        bit got_req = 0, got_ufc = 0, got_user = 0, got_link = 0, got_idle = 1;
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
                if (has(line, "deadbeef") || has(line, "dead")) got_idle = 0;   // ust 64 bit log'a girmemeli
            end
            if (fd != 0) $fclose(fd);
            chk(got_req,  "A7 log: UFC_REQ ms=3 (4 bayt)");
            chk(got_ufc,  "A7 log: UFC_TX ham veri");
            chk(got_user, "A7 log: USER_TX alt 128 bit");
            chk(got_link, "A7 log: LINK channel_up=1");
            chk(got_idle, "A7 log: ust 64 bit yazilmadi");
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
