`timescale 1ns / 1ps

// =====================================================================
// tb_fill_check : circular buffer DOLDURMA / SARMA testi  (v1.0.4)
//
// FPGA'yi taklit eder; gercek tasarimin yazdigina benzer bir trafik uretir:
//   - mesajlar 32 baytlik TLP'lere bolunur (FPGA 72 baytlik mesaji 32+32+8 yazmisti)
//   - her mesajdan sonra 8 baytlik pointer TLP'si
//   - her tur: 1DEA0005 (16 veri), sonra 3'lu grup 1DEA0007 (64), 1DEA000B (8), 1DEA0F09 (4)
//     ve grup icin 3 kesme (ilki hepsini okur, kalan ikisi sahte)
//   - buffer 256 bayt: ack(8) + 2 tur(2x124) = tam 256 -> buffer SONUNDA TAM BITIS
//
// Iki mod:
//   tur 0..5  : FPGA yazmayi buffer sonunda IKI TLP'ye boler,  pointer = base+size (sonda)
//   tur 6..11 : FPGA'nin 32B'lik TLP'si buffer sonunu ASAR (VIP basa sarar), pointer = base
// Son olarak: okunmamis verinin ustune yazma (BUFFER TASMASI) tespit edilir.
// =====================================================================
module tb_fill_check;
    import cpu_pkg::*;

    localparam bit [63:0] BASE = 64'h10000;
    localparam bit [63:0] SIZE = 64'h100;
    localparam bit [63:0] PTRA = 64'h20000;
    localparam bit [63:0] ENDA = BASE + SIZE;

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
        .INPUT_FILE("scenario_fill_cfg.txt"),
        .OUT_PREFIX("cpu_out_fill"),
        .TRACE_FILE("rq_trace_fill.txt")
    ) dut (
        .sys_clk(sys_clk), .user_clk(user_clk), .user_reset(user_reset),
        .m_axis_cq_tdata(cq_tdata), .m_axis_cq_tkeep(cq_tkeep), .m_axis_cq_tlast(cq_tlast),
        .m_axis_cq_tready(1'b1), .m_axis_cq_tuser(cq_tuser), .m_axis_cq_tvalid(cq_tvalid),
        .s_axis_rq_tdata(rq_tdata), .s_axis_rq_tkeep(rq_tkeep), .s_axis_rq_tlast(rq_tlast),
        .s_axis_rq_tready(rq_tready), .s_axis_rq_tuser(rq_tuser), .s_axis_rq_tvalid(rq_tvalid),
        .cfg_interrupt_msi_int(msi_int), .cfg_interrupt_msi_sent(msi_sent), .cfg_interrupt_msi_fail(msi_fail),
        .huzme_basi_obs(1'b0), .huzme_basi_gen(hb_gen)
    );

    string       expected[$];
    bit [63:0]   wp = BASE;        // FPGA'nin yazma konumu (mutlak adres)
    int          errors = 0;
    int unsigned exp_wraps = 0;    // beklenen "tek TLP buffer sonunu asti" sayisi
    int unsigned exp_spurious = 0;

    function automatic string fmt_msg(bit [31:0] id, bit [7:0] d[$]);
        string s = $sformatf("%08X %0d", id, d.size());
        foreach (d[i]) s = {s, $sformatf(" %02X", d[i])};
        return s;
    endfunction

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
            rq_tuser  <= first ? {54'b0, ((dw > 1) ? 4'hF : 4'h0), 4'hF} : 62'b0;
            @(posedge user_clk);
            if (rq_tready[0]) begin off += n; first = 1'b0; end
        end
        rq_tvalid <= 1'b0;
        rq_tlast  <= 1'b0;
    endtask

    task automatic fpga_ptr(bit [63:0] v);
        bit [7:0] p[$];
        p.delete();
        for (int i = 0; i < 8; i++) p.push_back(v[8*i +: 8]);
        send_rq(PTRA, p);
    endtask

    // Mesaji 32 baytlik TLP'ler halinde buffer'a yazar, ardindan pointer TLP'si gonderir.
    //   one_tlp=0 : TLP buffer sonunu asacaksa FPGA onu sonda iki TLP'ye boler
    //   one_tlp=1 : TLP buffer sonunu asar (VIP basa sarar)
    //   ptr_end : mesaj tam sonda bitince pointer = base+size mi (1), base mi (0)
    //   expect_out=0 : mesaj ISR tarafindan okunmayacak (tasma testi)
    task automatic fpga_msg(bit [31:0] id, int len, bit one_tlp, bit ptr_end, bit expect_out = 1'b1);
        bit [7:0]  d[$], m[$], chunk[$];
        int        total, pos, n, room;
        bit [63:0] pv;
        d.delete(); m.delete();
        for (int i = 0; i < len; i++) d.push_back(8'(id[7:0] + i));
        for (int i = 0; i < 4; i++) m.push_back(id[8*i +: 8]);
        for (int i = 0; i < 4; i++) m.push_back(len[8*i +: 8]);
        foreach (d[i]) m.push_back(d[i]);
        if (expect_out) expected.push_back(fmt_msg(id, d));

        total = m.size();
        pos   = 0;
        while (pos < total) begin
            if (wp == ENDA) wp = BASE;
            n    = ((total - pos) < 32) ? (total - pos) : 32;
            room = int'(ENDA - wp);
            if (n > room && !one_tlp) n = room;       // FPGA sonda boler
            chunk.delete();
            for (int i = 0; i < n; i++) chunk.push_back(m[pos + i]);
            send_rq(wp, chunk);
            if (n > room) begin                     // tek TLP buffer sonunu asti
                exp_wraps++;
                wp = BASE + (n - room);
            end else begin
                wp = wp + n;
            end
            pos += n;
        end
        pv = wp;
        if (pv == ENDA && !ptr_end) pv = BASE;      // sonda bitis: pointer'in stili
        fpga_ptr(pv);
    endtask

    task automatic fpga_irq();
        @(posedge user_clk);
        msi_int <= 32'h1;
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

    task automatic compare_output();
        int    fd, code, idx;
        string line;
        fd = $fopen("cpu_out_fill_sifpga.txt", "r");
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

    initial begin
        bit one_tlp, ptr_end;
        wait (dut.cpu != null);
        wait (dut.cpu.buffers[0].valid);
        #1000;

        // FPGA'nin config'e cevabi: 8 baytlik (len=0) mesaj
        $display("[TB] ack mesaji");
        fpga_msg(32'h1DEA0001, 0, 1'b0, 1'b1);
        fpga_irq();

        for (int r = 0; r < 12; r++) begin
            one_tlp   = (r >= 6);
            ptr_end = (r < 6);
            $display("[TB] tur %0d (%s)", r + 1, one_tlp ? "tek TLP buffer sonunu asar" : "FPGA sonda boler");
            fpga_msg(32'h1DEA0005, 16, one_tlp, ptr_end);
            fpga_irq();
            fpga_msg(32'h1DEA0007, 64, one_tlp, ptr_end);
            fpga_msg(32'h1DEA000B, 8,  one_tlp, ptr_end);
            fpga_msg(32'h1DEA0F09, 4,  one_tlp, ptr_end);
            fpga_irq();                         // ilk kesme 3 mesaji birden okur
            fpga_irq();                         // sahte
            fpga_irq();                         // sahte
            exp_spurious += 2;
        end

        // ---- Tasma testi: okunmamis veri buffer boyutunu (256) asana kadar kesme verme ----
        $display("[TB] tasma testi: 12 x 24 bayt yaz, kesme verme");
        for (int i = 0; i < 12; i++) fpga_msg(32'hEE000000 + i, 16, 1'b0, 1'b1, 1'b0);
        #1000;

        $display("---------------- SONUC ----------------");
        compare_output();
        dut.cpu.report();
        check_int("mesaj sayisi",      dut.cpu.msg_count,     expected.size());
        check_int("sahte kesme",       dut.cpu.spurious_isr,  exp_spurious);
        check_int("buffer sarma",      dut.cpu.wrap_events,   exp_wraps);
        check_int("tasma olayi",       dut.cpu.overrun_count, 1);
        check_int("hata sayaci",       dut.cpu.error_count,   0);
        if (errors == 0) $display("[TB] *** TUM TESTLER GECTI ***");
        else             $display("[TB] *** %0d HATA ***", errors);
        $finish;
    end

    initial begin
        #2000000;
        $display("[TB] HATA: zaman asimi");
        $finish;
    end
endmodule
