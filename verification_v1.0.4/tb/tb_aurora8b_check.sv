`timescale 1ns / 1ps

// =====================================================================
// tb_aurora8b_check : Aurora 8b10b gozlemci VIP'inin (v1.0.4) kendi kendini kontrol eden testi
//   B1  tx_out_clk 125 MHz (8 ns)
//   B2  link sirasi: gt_powergood -> tx_lock -> sys_reset_out biter -> channel_up/lane_up
//   B3  RX bos
//   B4  kullanici verisi her zaman kabul edilir ve log'a yazilir
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

    wire        clk, channel_up, sys_reset, tx_lock, link_reset, rx_valid;
    wire [0:0]  lane_up, powergood;

    aurora_8b10b_vip #(.UNIT_NAME("tb"), .LINK_UP_CLKS(625)) dut (
        .s_axi_tx_tdata(tx_tdata), .s_axi_tx_tkeep(tx_tkeep), .s_axi_tx_tvalid(tx_tvalid),
        .s_axi_tx_tlast(tx_tlast), .s_axi_tx_tready(tx_tready),
        .m_axi_rx_tdata(), .m_axi_rx_tkeep(), .m_axi_rx_tvalid(rx_valid), .m_axi_rx_tlast(),
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
        bit got_user = 0, got_link = 0;
        begin
            fd = $fopen("aurora8b10b_obs_tb.txt", "r");
            chk(fd != 0, "B6 log dosyasi acildi");
            while (fd != 0 && !$feof(fd)) begin
                line = "";
                code = $fgets(line, fd);
                if (code == 0) break;
                if (has(line, "USER_TX data=cafef00d keep=f last=1")) got_user = 1;
                if (has(line, "LINK channel_up=1 lane_up=1")) got_link = 1;
            end
            if (fd != 0) $fclose(fd);
            chk(got_user, "B6 log: USER_TX");
            chk(got_link, "B6 log: LINK channel_up=1");
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
