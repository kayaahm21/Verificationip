`timescale 1ns/1ps
// Bellek teshisi (v1.0.8): sadece senaryo okuyucusunu calistirir; tasarim, VIP'ler, RSI yok.
//   +MODE=0 : dosyayi sadece $fgets ile satir satir okur (ayristirma yok)
//   +MODE=1 : generator.run() (tam ayristirma, mailbox'a koyma)
//   +MODE=2 : MODE=1 + mailbox'taki tum paketleri bosaltir
//   +STREAM=0 : (MODE 1/2) eski $fgets+tokenize yolu; 1 (varsayilan): $fgetc ile akisli okuma
//   +F=<dosya>
module tb_gen_only;
    import scn_pkg::*;
    logic clk = 0, rstn = 1;
    beam_if bif(clk);
    axis_tx_if axi(clk, rstn);
    virtual beam_if vb = bif;
    virtual axis_tx_if va = axi;
    mailbox #(scn_cmd) mbx = new();
    generator gen;
    scn_cmd c;
    string f, line;
    int mode, fd, code, nl, maxlen, npk, stream;
    initial begin
        if (!$value$plusargs("F=%s", f)) f = "input_huzme_MAX_tek_huzme.txt";
        if (!$value$plusargs("MODE=%d", mode)) mode = 1;
        if (!$value$plusargs("STREAM=%d", stream)) stream = 1;
        $display("[TESHIS] baslangic: MODE=%0d dosya=%s", mode, f);
        if (mode == 0) begin
            fd = $fopen(f, "r");
            if (fd == 0) $fatal(1, "dosya yok");
            nl = 0; maxlen = 0;
            while (!$feof(fd)) begin
                line = "";
                code = $fgets(line, fd);
                if (code == 0) break;
                nl++;
                if (line.len() > maxlen) maxlen = line.len();
                $display("[TESHIS] satir %0d okundu (%0d karakter)", nl, line.len());
            end
            $fclose(fd);
            $display("[TESHIS] MODE=0 bitti: %0d satir, en uzun satir %0d karakter", nl, maxlen);
        end else begin
            gen = new(mbx, f);
            gen.stream_read = (stream != 0);
            gen.run();
            $display("[TESHIS] generator.run() bitti, mailbox'ta %0d komut", mbx.num());
            if (mode == 2) begin
                npk = 0;
                while (mbx.num() > 0) begin mbx.get(c); npk++; end
                $display("[TESHIS] MODE=2 bitti: %0d komut bosaltildi", npk);
            end
        end
        $finish;
    end
endmodule
