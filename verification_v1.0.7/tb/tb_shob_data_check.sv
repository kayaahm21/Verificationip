`timescale 1ns / 1ps

// =====================================================================
// tb_shob_data_check (v1.0.7): SHOB VIP'inin huzme verisi (0x00000002) gondericisinin testi
//
// Iki SHOB VIP (shob_1 -> carpan 1, shob_2 -> carpan 2) ayni HUZPAR akisini (0000E001) alir; her HUZPAR icin
// ~5 us sonra m_axi_rx_* (192 bit) uzerinden huzme verisi mesaji beklenir. Kontroller:
//   S1  Iki mesaj (iki HUZPAR) sirayla gelir (kuyruk), mesaj ID = 00000002, LEN = 56 + M*N*8 + 992
//   S2  Govde: baslik (ICD tablosu: huzme_id, durum, M, darbe, ornek, 16..23 reserved, 4 GAC maskesi, HI kullanim), her ornek desene uyar
//       (I = +k*kod, Q = -k*kod; kod = ((m+1)<<15) | (n & 7FFF); ornek-ana: n -> m)
//   S3  beat sayisi ve tkeep: son beat disindakiler 24 bayt, son beat kismi (mesaj boyu 24'un kati degil)
//   S4  kuyruk: ikinci HUZPAR, birinci veri gonderimi sirasinda gelir; mesajlar karismaz
//   S5  darbe=0 olan HUZPAR icin veri gonderilmez (atlandi)
// =====================================================================
module rx_checker #(
    parameter MUL = 1,
    parameter NMSG = 2,
    parameter [31:0] ID0 = 32'h0000AB12, parameter [15:0] M0 = 4, parameter [31:0] D0 = 2, parameter [31:0] O0 = 4,
    parameter [31:0] ID1 = 32'h0000CD34, parameter [15:0] M1 = 8, parameter [31:0] D1 = 3, parameter [31:0] O1 = 4,
    parameter [7:0] K0 = 8'h01, parameter [7:0] K1 = 8'h07      // HUZPAR kart kullanim durumu (HI kullanim = K >> 1)
)(
    input wire         clk,
    input wire         valid,
    input wire [191:0] data,
    input wire [23:0]  keep,
    input wire         last
);
    reg [7:0] rb [0:65535];
    integer   n = 0;            // bu mesajdaki bayt
    integer   beats = 0;
    integer   nmsg = 0;
    integer   errors = 0;
    integer   i, j, p;
    reg [23:0] lastkeep;
    reg [31:0] eid, em, ed, eo, en, elen, w, s, nn, mm, code, val;
    integer   total, expbeats, expkeepn, kn;
    reg [31:0] r32;
    reg [15:0] r16;

    task bad(input [8*80-1:0] msg);
        begin
            errors = errors + 1;
            $display("[RXCHK mul=%0d] HATA (mesaj %0d): %0s", MUL, nmsg, msg);
        end
    endtask

    always @(posedge clk) begin
        if (valid) begin
            // son beat disinda tkeep tam olmali
            if (!last && keep !== 24'hFFFFFF) bad("son olmayan beat'te tkeep tam degil");
            for (j = 0; j < 24; j = j + 1)
                if (keep[j]) begin rb[n] = data[8*j +: 8]; n = n + 1; end
            beats = beats + 1;
            if (last) begin
                lastkeep = keep;
                // beklenen parametreler
                if (nmsg == 0) begin eid = ID0; em = M0; ed = D0; eo = O0; end
                else           begin eid = ID1; em = M1; ed = D1; eo = O1; end
                en    = ed * eo;
                elen  = 56 + em * en * 8 + 992;
                total = 8 + elen;
                expbeats = (total + 23) / 24;
                kn = total - (expbeats - 1) * 24;
                if (n != total) bad("toplam bayt beklenenden farkli");
                if (beats != expbeats) bad("beat sayisi beklenenden farkli");
                // kismi son beat: ilk kn bit 1
                if (lastkeep !== ((24'd1 << kn) - 24'd1)) bad("son beat tkeep beklenenden farkli");
                r32 = {rb[3], rb[2], rb[1], rb[0]};     if (r32 !== 32'h00000002) bad("ID != 00000002");
                r32 = {rb[7], rb[6], rb[5], rb[4]};     if (r32 !== elen) bad("LEN beklenenden farkli");
                r32 = {rb[11], rb[10], rb[9], rb[8]};   if (r32 !== eid) bad("huzme_id");
                r16 = {rb[13], rb[12]};                 if (r16 !== 16'd1) bad("durum (HO=1)");
                r16 = {rb[15], rb[14]};                 if (r16 !== em[15:0]) bad("baslik M");
                r32 = {rb[19], rb[18], rb[17], rb[16]}; if (r32 !== ed) bad("baslik darbe");
                r32 = {rb[23], rb[22], rb[21], rb[20]}; if (r32 !== eo) bad("baslik ornek");
                for (i = 24; i < 32; i = i + 1) if (rb[i] !== 8'h00) bad("baslik 16..23 reserved sifir degil");
                for (i = 32; i < 48; i = i + 4) begin
                    r32 = {rb[i+3], rb[i+2], rb[i+1], rb[i]};
                    if (r32 !== 32'h3FFFFFFF) bad("baslik GAC kullanim durumu 3FFFFFFF degil");
                end
                if (rb[48] !== (((nmsg == 0 ? K0 : K1) >> 1) & 8'h07)) bad("baslik HI kullanim durumu");
                for (i = 49; i < 64; i = i + 1) if (rb[i] !== 8'h00) bad("baslik 41..55 reserved sifir degil");
                // ornekler
                for (i = 0; i < em * en; i = i + 1) begin
                    nn = i / em; mm = i - nn * em;
                    code = ((mm + 1) << 15) | (nn & 32'h7FFF);
                    p = 64 + i * 8;
                    r32 = {rb[p+3], rb[p+2], rb[p+1], rb[p]};
                    val = MUL * code;
                    if (r32 !== val) begin bad("I ornegi desene uymuyor"); i = em * en; end
                    else begin
                        r32 = {rb[p+7], rb[p+6], rb[p+5], rb[p+4]};
                        val = 32'd0 - MUL * code;
                        if (r32 !== val) begin bad("Q ornegi desene uymuyor"); i = em * en; end
                    end
                end
                // kuyruk (GAC SCIT 960 + SHOB SCIT 16 + reserved 16)
                for (i = 64 + em * en * 8; i < total; i = i + 1)
                    if (rb[i] !== 8'h00) bad("kuyruk baytlari sifir degil");
                $display("[RXCHK mul=%0d] mesaj %0d: id=%h M=%0d N=%0d bayt=%0d beat=%0d son_keep=%0d bayt -> %0s", MUL, nmsg,
                         eid, em, en, n, beats, kn, (errors == 0) ? "OK" : "HATALI");
                nmsg = nmsg + 1;
                n = 0; beats = 0;
            end
        end
    end
endmodule

module tb_shob_data_check;
    reg  [191:0] tx_tdata = 192'd0;
    reg  [23:0]  tx_tkeep = 24'd0;
    reg          tx_tlast = 1'b0, tx_tvalid = 1'b0;
    wire         tx_tready1, tx_tready2;
    reg          refclk = 1'b0;
    always #2 refclk = ~refclk;

    wire         uclk1, uclk2, cu1, cu2;
    wire [191:0] rx_d1, rx_d2;
    wire [23:0]  rx_k1, rx_k2;
    wire         rx_l1, rx_l2, rx_v1, rx_v2;

    // UFC portlari bos
    wire [191:0] ufc_rx_d1, ufc_rx_d2;
    wire [23:0]  ufc_rx_k1, ufc_rx_k2;
    wire         ufc_rx_l1, ufc_rx_l2, ufc_rx_v1, ufc_rx_v2;
    wire         ufc_t1, ufc_t2;

    `define SHOB_PORTS(sfx, utx_ready, udata, ukeep, ulast, uvalid) \
        .s_axi_tx_tdata(tx_tdata), .s_axi_tx_tlast(tx_tlast), .s_axi_tx_tkeep(tx_tkeep), \
        .s_axi_tx_tvalid(tx_tvalid), .s_axi_tx_tready(utx_ready), \
        .m_axi_rx_tdata(udata), .m_axi_rx_tlast(ulast), .m_axi_rx_tkeep(ukeep), .m_axi_rx_tvalid(uvalid), \
        .ufc_tx_req(1'b0), .ufc_tx_ms(8'd3), .s_axi_ufc_tx_tdata(192'd0), .s_axi_ufc_tx_tvalid(1'b0), \
        .s_axi_ufc_tx_tready(), \
        .rxp(3'b000), .rxn(3'b111), .txp(), .txn(), \
        .gt_refclk1_p(refclk), .gt_refclk1_n(~refclk), .gt_refclk1_out(), \
        .hard_err(), .soft_err(), .crc_pass_fail_n(), .crc_valid(), \
        .mmcm_not_locked_out(), .sync_clk_out(), \
        .reset_pb(1'b0), .gt_rxcdrovrden_in(1'b0), .power_down(1'b0), .loopback(3'b000), \
        .pma_init(1'b0), .gt_pll_lock(), .init_clk(refclk), .link_reset_out(), .gt_powergood(), \
        .sys_reset_out(), .gt_reset_out(), .tx_out_clk()

    aurora_64b66b_vip #(.UNIT_NAME("shob_1")) dut1 (
        `SHOB_PORTS(1, tx_tready1, rx_d1, rx_k1, rx_l1, rx_v1),
        .m_axi_ufc_rx_tdata(ufc_rx_d1), .m_axi_ufc_rx_tkeep(ufc_rx_k1), .m_axi_ufc_rx_tlast(ufc_rx_l1),
        .m_axi_ufc_rx_tvalid(ufc_rx_v1), .ufc_in_progress(),
        .channel_up(cu1), .lane_up(), .user_clk_out(uclk1)
    );
    aurora_64b66b_vip #(.UNIT_NAME("shob_2")) dut2 (
        `SHOB_PORTS(2, tx_tready2, rx_d2, rx_k2, rx_l2, rx_v2),
        .m_axi_ufc_rx_tdata(ufc_rx_d2), .m_axi_ufc_rx_tkeep(ufc_rx_k2), .m_axi_ufc_rx_tlast(ufc_rx_l2),
        .m_axi_ufc_rx_tvalid(ufc_rx_v2), .ufc_in_progress(),
        .channel_up(cu2), .lane_up(), .user_clk_out(uclk2)
    );

    // beklenen: iki mesaj (S5 darbe=0 olan ucuncu HUZPAR icin mesaj YOK)
    rx_checker #(.MUL(1)) chk1 (.clk(uclk1), .valid(rx_v1), .data(rx_d1), .keep(rx_k1), .last(rx_l1));
    rx_checker #(.MUL(2)) chk2 (.clk(uclk2), .valid(rx_v2), .data(rx_d2), .keep(rx_k2), .last(rx_l2));

    // ---- HUZPAR mesaji ureticisi (16 baytlik beat'ler) ----
    reg [7:0] tb_m [0:16383];
    integer   tb_n = 0;
    task put8(input [7:0] v);   begin tb_m[tb_n] = v; tb_n = tb_n + 1; end endtask
    task put16(input [15:0] v); begin put8(v[7:0]); put8(v[15:8]); end endtask
    task put32(input [31:0] v); begin put16(v[15:0]); put16(v[31:16]); end endtask
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
                @(negedge uclk1);
                tx_tdata <= {64'd0, d}; tx_tkeep <= kp; tx_tlast <= (rem <= 16); tx_tvalid <= 1'b1;
            end
            @(negedge uclk1);
            tx_tvalid <= 1'b0; tx_tlast <= 1'b0; tx_tkeep <= 24'd0;
            repeat (3) @(negedge uclk1);
            tb_n = 0;
        end
    endtask
    task put_huzpar(input [31:0] hid, input [15:0] nb, input [31:0] darbe, input [31:0] ornek, input [7:0] kart);
        integer r;
        begin
            put32(32'h0000E001); put32(32'd56 + nb * 1920);
            put32(hid); put16(16'd1); put16(nb); put32(darbe); put32(ornek);
            put32(32'h3FFFFFFF); put32(32'h3FFFFFFF); put32(32'h3FFFFFFF); put32(32'h3FFFFFFF);
            put8(kart); put8(8'h00);
            for (r = 0; r < 22; r = r + 1) put8(8'h00);
            for (r = 0; r < nb * 1920; r = r + 1) put8(8'h00);
        end
    endtask

    integer errors = 0;
    task chk(input cond, input [8*72-1:0] msg);
        begin
            if (!cond) begin $display("[TB] HATA: %0s", msg); errors = errors + 1; end
            else       $display("[TB] tamam: %0s", msg);
        end
    endtask

    function integer count_in(input string fname, input string pat);
        integer fd, code, cnt;
        string  line, sp;
        begin
            cnt = 0;
            fd = $fopen(fname, "r");
            sp = pat;
            while (fd != 0 && !$feof(fd)) begin
                line = "";
                code = $fgets(line, fd);
                if (code == 0) break;
                if (line.len() >= sp.len())
                    for (code = 0; code <= line.len() - sp.len(); code = code + 1)
                        if (line.substr(code, code + sp.len() - 1) == sp) begin cnt = cnt + 1; code = line.len(); end
            end
            if (fd != 0) $fclose(fd);
            count_in = cnt;
        end
    endfunction

    initial begin
        wait (cu1 && cu2);
        repeat (20) @(negedge uclk1);
        put_huzpar(32'h0000AB12, 16'd4, 32'd2, 32'd4, 8'h01);    // N=8 : 1312 bayt, 55 beat, son beat 16 bayt
        send_msg16;
        put_huzpar(32'h0000CD34, 16'd8, 32'd3, 32'd4, 8'h07);    // N=12: 56+8*12*8+992 = 1816 -> mesaj 1824 bayt = 76 beat tam
        send_msg16;
        put_huzpar(32'h0000EF56, 16'd4, 32'd0, 32'd4, 8'h01);    // darbe=0: veri yok
        send_msg16;
        repeat (3000) @(negedge uclk1);

        chk(chk1.nmsg == 2 && chk2.nmsg == 2, "S1 her iki SHOB'ta tam 2 huzme verisi mesaji alindi");
        chk(chk1.errors == 0, "S2/S3 shob_1 mesajlari (carpan 1) dogru");
        chk(chk2.errors == 0, "S2/S3 shob_2 mesajlari (carpan 2) dogru");
        chk(count_in("aurora_huzme_shob_1.txt", "HUZME_VERI_BASLADI huzme_id=0000ab12 M=4 darbe=2 ornek=4 N=8 carpan=1") == 1, "S4 shob_1 log: 1. mesaj basladi");
        chk(count_in("aurora_huzme_shob_1.txt", "HUZME_VERI_BASLADI huzme_id=0000cd34 M=8 darbe=3 ornek=4 N=12 carpan=1") == 1, "S4 shob_1 log: 2. mesaj basladi");
        chk(count_in("aurora_huzme_shob_2.txt", "N=8 carpan=2") == 1 && count_in("aurora_huzme_shob_2.txt", "N=12 carpan=2") == 1, "S4 shob_2 log: carpan=2");
        chk(count_in("aurora_huzme_shob_1.txt", "HUZME_VERI_ATLANDI huzme_id=0000ef56") == 1, "S5 darbe=0: veri atlandi");

        if (errors == 0) $display("[TB] *** TUM TESTLER GECTI ***");
        else             $display("[TB] *** %0d HATA ***", errors);
        $finish;
    end
endmodule
