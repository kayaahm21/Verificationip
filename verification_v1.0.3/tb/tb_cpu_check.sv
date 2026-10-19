`timescale 1ns / 1ps

// =====================================================================
// tb_cpu_check : islemci modelinin (v1.0.3) kendi kendini kontrol eden testi
//
// FPGA'yi TAKLIT EDER: s_axis_rq portuna memory write TLP'leri ve MSI verir,
// sonra islemci modelinin yazdigi cpu_out.txt'yi beklenen satirlarla karsilastirir.
//
// Buffer (examples/scenario_v103.txt ile programlanir): base=0x1000, boyut=64, pointer adresi=0x2000
//
// Senaryolar:
//   T1  veri, pointer, kesme                          -> 1 mesaj
//   T2  veri1, ptr1, veri2, ptr2, TEK kesme           -> 2 mesaj (birlesmis kesme)
//   T3  buffer sonuna denk gelen yazma, FPGA IKI TLP'ye boler -> mesaj bozulmadan cikar
//   T4  tek TLP buffer sonunu asar (VIP basa sarar, uyari)    -> mesaj bozulmadan cikar
//   T5  yeni veri yokken kesme                        -> sahte kesme, cikti yok
//   T6  veri yazildi ama pointer henuz yok + kesme    -> okunmaz; pointer sonra gelince okunur
//   T7  len=0 mesaj
//   T8  8 baytlik pointer yazimi
//   T9  mesaj buffer'i tam sonda bitirir, pointer = base+size  -> normallesir
// =====================================================================
module tb_cpu_check;
    import cpu_pkg::*;

    localparam bit [63:0] BASE = 64'h1000;
    localparam bit [63:0] SIZE = 64'h40;
    localparam bit [63:0] PTRA = 64'h2000;
    localparam bit [63:0] ENDA = BASE + SIZE;

    // ---- DUT sinyalleri ----
    logic         sys_clk = 1'b0;
    logic         user_clk, user_reset;
    logic [255:0] cq_tdata;
    logic [7:0]   cq_tkeep;
    logic         cq_tlast, cq_tvalid;
    logic [87:0]  cq_tuser;
    logic [255:0] rq_tdata  = '0;
    logic [7:0]   rq_tkeep  = '0;
    logic         rq_tlast  = 1'b0;
    logic [61:0]  rq_tuser  = '0;
    logic         rq_tvalid = 1'b0;
    logic [3:0]   rq_tready;
    logic [31:0]  msi_int   = '0;
    logic         msi_sent, msi_fail;
    logic         hb_gen;

    sim_model_cpu #(
        .INPUT_FILE("scenario_v103.txt"),
        .OUT_FILE("cpu_out.txt"),
        .TRACE_FILE("rq_trace.txt")
    ) dut (
        .sys_clk(sys_clk), .user_clk(user_clk), .user_reset(user_reset),
        .m_axis_cq_tdata(cq_tdata), .m_axis_cq_tkeep(cq_tkeep), .m_axis_cq_tlast(cq_tlast),
        .m_axis_cq_tready(1'b1), .m_axis_cq_tuser(cq_tuser), .m_axis_cq_tvalid(cq_tvalid),
        .s_axis_rq_tdata(rq_tdata), .s_axis_rq_tkeep(rq_tkeep), .s_axis_rq_tlast(rq_tlast),
        .s_axis_rq_tready(rq_tready), .s_axis_rq_tuser(rq_tuser), .s_axis_rq_tvalid(rq_tvalid),
        .cfg_interrupt_msi_int(msi_int), .cfg_interrupt_msi_sent(msi_sent), .cfg_interrupt_msi_fail(msi_fail),
        .huzme_basi_obs(1'b0), .huzme_basi_gen(hb_gen)
    );

    // ---- FPGA modeli ----
    string     expected[$];   // beklenen cikti satirlari
    bit [63:0] wp = BASE;     // FPGA'nin yazma konumu (mutlak adres)
    int        errors = 0;

    // Bir mesajin cikti satiri: "MSGID LEN B0 B1 ..."
    function automatic string fmt_msg(bit [31:0] id, bit [7:0] d[$]);
        string s = $sformatf("%08X %0d", id, d.size());
        foreach (d[i]) s = {s, $sformatf(" %02X", d[i])};
        return s;
    endfunction

    // RQ uzerinden bir memory write TLP'si surer (payload DWORD'un kati olmali)
    task automatic send_rq(bit [63:0] addr, bit [7:0] payload[$]);
        bit [7:0]  pkt[$];
        int        dw = payload.size() / 4;
        bit [31:0] dw0, dw1, dw2, dw3;
        int        off, n;
        bit [255:0] word;
        bit [7:0]  keep;
        bit        first;
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
        @(posedge user_clk);
        while (off < pkt.size()) begin
            n = ((pkt.size() - off) < 32) ? (pkt.size() - off) : 32;
            word = '0; keep = '0;
            for (int b = 0; b < n; b++) begin
                word[8*b +: 8] = pkt[off + b];
                keep[b / 4]    = 1'b1;
            end
            rq_tvalid <= 1'b1;
            rq_tdata  <= word;
            rq_tkeep  <= keep;
            rq_tlast  <= (off + n >= pkt.size());
            rq_tuser  <= first ? {54'b0, ((dw > 1) ? 4'hF : 4'h0), 4'hF} : 62'b0;   // last_be, first_be
            @(posedge user_clk);
            if (rq_tready[0]) begin off += n; first = 1'b0; end
        end
        rq_tvalid <= 1'b0;
        rq_tlast  <= 1'b0;
    endtask

    // Pointer degerini (4 veya 8 bayt, little-endian) ptr adresine yazar
    task automatic fpga_ptr(bit [63:0] v, int width);
        bit [7:0] p[$];
        for (int i = 0; i < width; i++) p.push_back(v[8*i +: 8]);
        send_rq(PTRA, p);
    endtask

    // Bir mesaj uretir ve buffer'a yazar.
    //   one_tlp=0 : buffer sonunu asarsa FPGA iki TLP'ye boler
    //   one_tlp=1 : tek TLP (buffer sonunu asar)
    //   commit  : 1 ise ardindan pointer TLP'si de gonderir
    task automatic fpga_msg(bit [31:0] id, int len, bit one_tlp, bit commit, int pwidth = 4);
        bit [7:0] d[$];
        bit [7:0] m[$];
        bit [7:0] a[$], b[$];
        int       room, total;
        for (int i = 0; i < len; i++) d.push_back(8'(id[7:0] + i));
        for (int i = 0; i < 4; i++) m.push_back(id[8*i +: 8]);
        for (int i = 0; i < 4; i++) m.push_back(len[8*i +: 8]);
        foreach (d[i]) m.push_back(d[i]);
        expected.push_back(fmt_msg(id, d));

        total = m.size();
        if (wp == ENDA) wp = BASE;
        room = int'(ENDA - wp);
        if (total <= room || one_tlp) begin
            send_rq(wp, m);
            wp = wp + total;
            if (wp > ENDA) wp = BASE + (wp - ENDA);   // tek TLP tasti, VIP tasan kismi basa sardi
        end else begin
            for (int i = 0; i < room; i++)  a.push_back(m[i]);
            for (int i = room; i < total; i++) b.push_back(m[i]);
            send_rq(wp, a);
            send_rq(BASE, b);
            wp = BASE + (total - room);
        end
        if (commit) fpga_ptr(wp, pwidth);
    endtask

    // MSI: msi_int'i sent gelene kadar tut (UltraScale+ protokolu), sonra ISR'nin bitmesini bekle
    task automatic fpga_irq();
        @(posedge user_clk);
        msi_int <= 32'h1;
        do @(posedge user_clk); while (msi_sent !== 1'b1);
        msi_int <= 32'h0;
        #500;
    endtask

    // ---- sonuc kontrolu ----
    task automatic check_int(string name, int got, int exp);
        if (got !== exp) begin
            $display("[TB] HATA: %s = %0d (beklenen %0d)", name, got, exp);
            errors++;
        end else
            $display("[TB] tamam: %s = %0d", name, got);
    endtask

    task automatic compare_output();
        int    fd, code, idx;
        string line;
        fd = $fopen("cpu_out.txt", "r");
        idx = 0;
        while (fd != 0 && !$feof(fd)) begin
            line = "";
            code = $fgets(line, fd);
            if (code == 0) break;
            while (line.len() > 0 && (line.getc(line.len() - 1) == "\n" || line.getc(line.len() - 1) == "\r"))
                line = line.substr(0, line.len() - 2);
            if (line.len() == 0) continue;
            if (idx >= expected.size()) begin
                $display("[TB] HATA: beklenmeyen satir: %s", line);
                errors++;
            end else if (line != expected[idx]) begin
                $display("[TB] HATA: satir %0d farkli\n   gelen   : %s\n   beklenen: %s", idx + 1, line, expected[idx]);
                errors++;
            end
            idx++;
        end
        if (fd != 0) $fclose(fd);
        if (idx != expected.size()) begin
            $display("[TB] HATA: %0d satir bekleniyordu, %0d geldi", expected.size(), idx);
            errors++;
        end else
            $display("[TB] cikti dosyasi %0d satir, hepsi beklenenle ayni", idx);
    endtask

    // ---- ana akis ----
    initial begin
        // Buffer, senaryodaki 1DEA0001 mesajiyla programlanana kadar bekle
        wait (dut.cpu != null);
        wait (dut.cpu.buffer.valid);
        #1000;

        $display("[TB] T1: veri, pointer, kesme");
        fpga_msg(32'hA1, 12, 1'b0, 1'b1);
        fpga_irq();

        $display("[TB] T2: iki (veri+pointer), tek kesme");
        fpga_msg(32'hB1, 4, 1'b0, 1'b1);
        fpga_msg(32'hB2, 8, 1'b0, 1'b1);
        fpga_irq();

        $display("[TB] T3: buffer sonuna denk gelen yazma, FPGA iki TLP'ye boler");
        fpga_msg(32'hC1, 24, 1'b0, 1'b1);
        fpga_irq();

        $display("[TB] T4: tek TLP buffer sonunu asar");
        fpga_msg(32'hD1, 16, 1'b0, 1'b1);
        fpga_irq();
        fpga_msg(32'hD2, 24, 1'b1, 1'b1);
        fpga_irq();

        $display("[TB] T5: yeni veri yokken kesme (sahte)");
        fpga_irq();

        $display("[TB] T6: veri yazildi, pointer henuz yok");
        fpga_msg(32'hE1, 8, 1'b0, 1'b0);
        fpga_irq();                    // pointer eski -> okunmamali
        fpga_ptr(wp, 4);
        fpga_irq();                    // simdi okunmali

        $display("[TB] T7: len=0 mesaj");
        fpga_msg(32'hF1, 0, 1'b0, 1'b1);
        fpga_irq();

        $display("[TB] T8: 8 baytlik pointer");
        fpga_msg(32'hA8, 4, 1'b0, 1'b1, 8);
        fpga_irq();

        $display("[TB] T9: mesaj buffer'i tam sonda bitirir (pointer = base+size)");
        fpga_msg(32'hB9, 12, 1'b0, 1'b1);
        fpga_irq();
        fpga_msg(32'hC9, 4, 1'b0, 1'b1);   // bir sonraki mesaj basa yazilir
        fpga_irq();

        #1000;
        $display("---------------- SONUC ----------------");
        compare_output();
        dut.cpu.report();
        check_int("mesaj sayisi",      dut.cpu.msg_count,    expected.size());
        check_int("sahte kesme",       dut.cpu.spurious_isr, 2);
        check_int("buffer sarma",      dut.cpu.wrap_events,  1);
        check_int("hata sayaci",       dut.cpu.error_count,  0);
        if (errors == 0) $display("[TB] *** TUM TESTLER GECTI ***");
        else             $display("[TB] *** %0d HATA ***", errors);
        $finish;
    end

    initial begin
        #200000;
        $display("[TB] HATA: zaman asimi");
        $finish;
    end
endmodule
