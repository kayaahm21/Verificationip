`timescale 1ns / 1ps

// =====================================================================
// tb_multi_check : 4 buffer'li islemci modelinin (v1.0.4) kendi kendini kontrol eden testi
//
// FPGA'yi TAKLIT EDER. examples/scenario_v104.txt 4 buffer'i programlar:
//   SIFPGA 0x1000/64 (ptr 0x2000)   SHOB1 0x3000/64 (ptr 0x4000)
//   SHOB2  0x5000/64 (ptr 0x6000)   IUB   0x7000/64 (ptr 0x8000)
//
// Senaryolar:
//   M1  4 buffer'a da mesaj, tek kesme vektoru 0b001111  -> 4 dosyada birer satir
//   M2  SIFPGA+SHOB1 verisi hazir, vektor 0b000010       -> yalnizca SHOB1 okunur
//       sonra vektor 0b000001                            -> SIFPGA okunur
//   M3  RSI vektoru 0b110000                             -> hicbir dosyaya yazilmaz, msi_sent yine gelir
//   M4  IUB icin vektor 0b001000, SHOB2 sarma testi      -> mesajlar bozulmadan ciksin
// =====================================================================
module tb_multi_check;
    import cpu_pkg::*;

    localparam bit [63:0] BASE [4] = '{64'h1000, 64'h3000, 64'h5000, 64'h7000};
    localparam bit [63:0] PTRA [4] = '{64'h2000, 64'h4000, 64'h6000, 64'h8000};
    localparam bit [63:0] SIZE     = 64'h40;
    localparam string     FNAME[4] = '{"cpu_out_multi_sifpga.txt", "cpu_out_multi_shob1.txt",
                                       "cpu_out_multi_shob2.txt",  "cpu_out_multi_iub.txt"};

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
        .INPUT_FILE("scenario_v104.txt"),
        .OUT_PREFIX("cpu_out_multi"),
        .TRACE_FILE("rq_trace_multi.txt")
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


    // ---- FPGA modeli ----
    string     expected[4][$];             // her buffer icin beklenen cikti satirlari
    bit [63:0] wp [4] = '{64'h1000, 64'h3000, 64'h5000, 64'h7000};   // buffer basina yazma konumu
    int        errors = 0;

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
        pkt.delete();     // otomatik yerel kuyruk: simulatorlerden bagimsiz olmak icin acikca temizle
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


    // Buffer bi'ye mesaj yazar (gerekirse sonda iki TLP'ye boler) ve pointer'i gunceller
    task automatic fpga_msg(int bi, bit [31:0] id, int len, bit commit = 1'b1);
        bit [7:0]  d[$], m[$], a[$], b[$], p[$];
        bit [63:0] end_a = BASE[bi] + SIZE;
        int        room, total;
        d.delete(); m.delete(); a.delete(); b.delete(); p.delete();
        for (int i = 0; i < len; i++) d.push_back(8'(id[7:0] + i));
        for (int i = 0; i < 4; i++) m.push_back(id[8*i +: 8]);
        for (int i = 0; i < 4; i++) m.push_back(len[8*i +: 8]);
        foreach (d[i]) m.push_back(d[i]);
        expected[bi].push_back(fmt_msg(id, d));
        total = m.size();
        if (wp[bi] == end_a) wp[bi] = BASE[bi];
        room = int'(end_a - wp[bi]);
        if (total <= room) begin
            send_rq(wp[bi], m);
            wp[bi] = wp[bi] + total;
        end else begin
            for (int i = 0; i < room; i++)     a.push_back(m[i]);
            for (int i = room; i < total; i++) b.push_back(m[i]);
            send_rq(wp[bi], a);
            send_rq(BASE[bi], b);
            wp[bi] = BASE[bi] + (total - room);
        end
        if (commit) begin
            for (int i = 0; i < 4; i++) p.push_back(wp[bi][8*i +: 8]);
            send_rq(PTRA[bi], p);
        end
    endtask

    // MSI: vektoru sent gelene kadar tut, sonra ISR'nin bitmesini bekle
    task automatic fpga_irq(bit [31:0] vec);
        @(posedge user_clk);
        msi_int <= vec;
        do @(posedge user_clk); while (msi_sent !== 1'b1);
        msi_int <= 32'h0;
        #500;
    endtask

    task automatic check_int(string name, int got, int exp);
        if (got !== exp) begin
            $display("[TB] HATA: %s = %0d (beklenen %0d)", name, got, exp);
            errors++;
        end else
            $display("[TB] tamam: %s = %0d", name, got);
    endtask

    // Bir buffer'in cikti dosyasini beklenenle karsilastirir
    task automatic compare_output(int bi);
        int    fd, code, idx;
        string line;
        fd = $fopen(FNAME[bi], "r");
        idx = 0;
        while (fd != 0 && !$feof(fd)) begin
            line = "";
            code = $fgets(line, fd);
            if (code == 0) break;
            while (line.len() > 0 && (line.getc(line.len() - 1) == "\n" || line.getc(line.len() - 1) == "\r"))
                line = line.substr(0, line.len() - 2);
            if (line.len() == 0) continue;
            if (idx >= expected[bi].size()) begin
                $display("[TB] HATA: %s beklenmeyen satir: %s", FNAME[bi], line);
                errors++;
            end else if (line != expected[bi][idx]) begin
                $display("[TB] HATA: %s satir %0d farkli\n   gelen   : %s\n   beklenen: %s",
                         FNAME[bi], idx + 1, line, expected[bi][idx]);
                errors++;
            end
            idx++;
        end
        if (fd != 0) $fclose(fd);
        if (idx != expected[bi].size()) begin
            $display("[TB] HATA: %s: %0d satir bekleniyordu, %0d geldi", FNAME[bi], expected[bi].size(), idx);
            errors++;
        end else
            $display("[TB] %s: %0d satir, hepsi beklenenle ayni", FNAME[bi], idx);
    endtask

    // Su anda dosyada kac satir var (kismi kontrol icin)
    function automatic int lines_in(int bi);
        int fd = $fopen(FNAME[bi], "r");
        int n = 0;
        string l;
        while (fd != 0 && !$feof(fd)) begin
            l = "";
            if ($fgets(l, fd) == 0) break;
            if (l.len() > 0) n++;
        end
        if (fd != 0) $fclose(fd);
        return n;
    endfunction

    initial begin
        wait (dut.cpu != null);
        wait (dut.cpu.buffers[0].valid && dut.cpu.buffers[1].valid &&
              dut.cpu.buffers[2].valid && dut.cpu.buffers[3].valid);
        #1000;

        $display("[TB] M1: 4 buffer'a mesaj, tek kesme vektoru 0b001111");
        fpga_msg(0, 32'hA1, 12);
        fpga_msg(1, 32'hB1, 8);
        fpga_msg(2, 32'hC1, 16);
        fpga_msg(3, 32'hD1, 4);
        fpga_irq(32'h0F);
        check_int("M1 sifpga satir", lines_in(0), 1);
        check_int("M1 shob1 satir",  lines_in(1), 1);
        check_int("M1 shob2 satir",  lines_in(2), 1);
        check_int("M1 iub satir",    lines_in(3), 1);

        $display("[TB] M2: vektor yalnizca SHOB1'i secer");
        fpga_msg(0, 32'hA2, 8);
        fpga_msg(1, 32'hB2, 8);
        fpga_irq(32'h02);
        check_int("M2 shob1 okundu",     lines_in(1), 2);
        check_int("M2 sifpga okunmadi",  lines_in(0), 1);
        fpga_irq(32'h01);
        check_int("M2 sifpga okundu",    lines_in(0), 2);

        $display("[TB] M3: RSI vektoru (henuz uygulanmadi)");
        fpga_irq(32'h30);
        check_int("M3 rsi yok sayildi", dut.cpu.rsi_ignored, 1);

        $display("[TB] M4: IUB tek vektor, SHOB2 sarma");
        fpga_msg(3, 32'hD2, 20);
        fpga_irq(32'h08);
        fpga_msg(2, 32'hC2, 20);
        fpga_irq(32'h04);
        fpga_msg(2, 32'hC3, 20);      // 64 baytlik buffer sonunu asar -> iki TLP
        fpga_irq(32'h04);
        fpga_msg(2, 32'hC4, 12);
        fpga_msg(2, 32'hC5, 4);
        fpga_irq(32'h04);

        $display("[TB] M5: tanimsiz MSI biti (bit 8) - uyari verilmeli, hicbir buffer okunmamali");
        fpga_irq(32'h100);
        check_int("M5 tanimsiz bit sayisi", dut.cpu.unknown_msi, 1);

        #1000;
        $display("---------------- SONUC ----------------");
        for (int i = 0; i < 4; i++) compare_output(i);
        dut.cpu.report();
        check_int("hata sayaci",   dut.cpu.error_count,   0);
        check_int("tasma",         dut.cpu.overrun_count, 0);
        check_int("buffer disi",   dut.cpu.stray_writes,  0);
        check_int("shob2 mesaj",   dut.cpu.buffers[2].msg_count, 5);
        if (errors == 0) $display("[TB] *** TUM TESTLER GECTI ***");
        else             $display("[TB] *** %0d HATA ***", errors);
        $finish;
    end

    initial begin
        #400000;
        $display("[TB] HATA: zaman asimi");
        $finish;
    end
endmodule
