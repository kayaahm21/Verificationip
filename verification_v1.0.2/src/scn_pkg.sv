`timescale 1ns / 1ps

// =====================================================================
// scn_pkg : Senaryo (scenario) tabanli TLP surme paketi  -  v1.0.2
//
// Icerik:
//   - Sabitler ve komut turleri (ozel adres degerleri)
//   - tlp_item   : tek bir TLP paketi
//   - scn_cmd    : senaryo dosyasindaki bir satirin komut karsiligi
//   - generator  : senaryo dosyasini satir satir okuyup scn_cmd uretir (parser)
//   - beam_ctrl  : huzme basi (HB) sinyalini izler / uretir
//   - driver     : scn_cmd'leri sirayla calistirir (TLP surer, bekler, HB planlar)
//
// Senaryo dosyasi satir formati (her satir bir komut, '#' veya '//' yorum):
//   ADRES   MSGID  LEN  BYTE0 BYTE1 ...   -> normal TLP (adres sihirli degilse)
//   99999999                               -> HB gelene kadar bekle
//   88888888  <ns>                         -> <ns> nanosaniye bekle
//   77777777  <ns>                         -> <ns> sonra HB darbesi uret (bloklamaz)
//
// Derleme sirasi: axis_tx_if.sv -> beam_if.sv -> scn_pkg.sv
// =====================================================================
package scn_pkg;

    // -----------------------------------------------------------------
    // Ozel (komut) adres degerleri. Satirin ILK alani bunlardan biriyse
    // satir bir TLP degil, komuttur.
    // -----------------------------------------------------------------
    localparam bit [63:0] ADDR_WAIT_BEAM = 64'h0000_0000_9999_9999;  // HB bekle
    localparam bit [63:0] ADDR_WAIT_NS   = 64'h0000_0000_8888_8888;  // zaman bekle
    localparam bit [63:0] ADDR_PLAN_BEAM = 64'h0000_0000_7777_7777;  // sonraki HB'yi planla

    // Komut turleri
    typedef enum int {
        CMD_TLP,        // TLP paketi sur
        CMD_WAIT_BEAM,  // HB'yi bekle
        CMD_WAIT_NS,    // ns bekle
        CMD_PLAN_BEAM,  // ns sonra HB uret
        CMD_END         // senaryo sonu (generator tarafindan dosya sonunda eklenir)
    } cmd_kind_e;


    // =================================================================
    // tlp_item : tek bir TLP paketi
    // =================================================================
    class tlp_item;
        bit [7:0] tlp_packet[];  // 16B descriptor + msg_id(4) + length(4) + payload(N)
        bit [3:0] first_be;      // ilk DWORD'un byte enable'i
        bit [3:0] last_be;       // son DWORD'un byte enable'i

        function new(int total_len);
            this.tlp_packet = new[total_len];
            this.first_be   = 4'b1111;
            this.last_be    = 4'b1111;
        endfunction
    endclass


    // =================================================================
    // scn_cmd : senaryo dosyasindaki bir satirin komut karsiligi
    // =================================================================
    class scn_cmd;
        cmd_kind_e       kind;     // komut turu
        tlp_item         tlp;      // sadece CMD_TLP icin dolu
        longint unsigned ns;       // CMD_WAIT_NS / CMD_PLAN_BEAM icin sure (ns)
        int              line_no;  // dosyadaki satir numarasi (log icin)

        function new(cmd_kind_e kind, int line_no = 0);
            this.kind    = kind;
            this.tlp     = null;
            this.ns      = 0;
            this.line_no = line_no;
        endfunction
    endclass


    // =================================================================
    // Yardimci fonksiyonlar (parser icin)
    // =================================================================

    // Onaltilik (hex) metni 64 bit sayiya cevirir. "0x" oneki ve '_' kabul edilir.
    // Basarisizsa (gecersiz karakter, bos, 16 haneden uzun) 0 doner.
    function automatic bit parse_hex(string s, output bit [63:0] val);
        int start = 0;
        int ndig  = 0;
        int digit;
        byte c;
        val = '0;
        if (s.len() >= 2 && s.getc(0) == "0" && (s.getc(1) == "x" || s.getc(1) == "X"))
            start = 2;
        for (int i = start; i < s.len(); i++) begin
            c = s.getc(i);
            if (c == "_") continue;
            if      (c >= "0" && c <= "9") digit = c - "0";
            else if (c >= "a" && c <= "f") digit = c - "a" + 10;
            else if (c >= "A" && c <= "F") digit = c - "A" + 10;
            else return 1'b0;
            val = (val << 4) | 64'(digit);
            ndig++;
        end
        return (ndig > 0 && ndig <= 16);
    endfunction

    // Onluk (decimal) metni 64 bit isaretsiz sayiya cevirir. Basarisizsa 0 doner.
    function automatic bit parse_dec(string s, output longint unsigned val);
        int ndig = 0;
        byte c;
        val = 0;
        for (int i = 0; i < s.len(); i++) begin
            c = s.getc(i);
            if (c < "0" || c > "9") return 1'b0;
            val = val * 10 + 64'(c - "0");
            ndig++;
        end
        return (ndig > 0);
    endfunction

    // Bir satiri bosluk/tab/virgul ile parcalara (token) boler.
    // '#' veya "//" gordugu yerden itibaren satirin geri kalani yorumdur.
    function automatic void tokenize(string line, ref string toks[$]);
        string cur = "";
        byte   c;
        int    n = line.len();
        toks.delete();
        for (int i = 0; i < n; i++) begin
            c = line.getc(i);
            if (c == "#") break;                                         // '#' yorumu
            if (c == "/" && (i + 1) < n && line.getc(i + 1) == "/") break; // "//" yorumu
            if (c == " " || c == "\t" || c == "\n" || c == "\r" || c == ",") begin
                if (cur.len() > 0) begin
                    toks.push_back(cur);
                    cur = "";
                end
            end else begin
                cur = {cur, line.substr(i, i)};
            end
        end
        if (cur.len() > 0) toks.push_back(cur);
    endfunction


    // =================================================================
    // generator : senaryo dosyasini okur, scn_cmd uretip mailbox'a koyar
    // =================================================================
    class generator;
        mailbox #(scn_cmd) mbx;
        string             file_name;

        function new(mailbox #(scn_cmd) mbx, string file_name = "input_data.txt");
            this.mbx       = mbx;
            this.file_name = file_name;
        endfunction

        // Dosyayi bastan sona okur. Hatali satirlar uyari ile atlanir.
        task run();
            int    fd;
            int    code;
            int    line_no = 0;
            string line;
            string toks[$];
            scn_cmd end_cmd;

            fd = $fopen(file_name, "r");
            if (fd == 0) $fatal(1, "[GEN-FATAL] Senaryo dosyasi bulunamadi: %s", file_name);

            while (!$feof(fd)) begin
                line = "";
                code = $fgets(line, fd);
                if (code == 0) break;
                line_no++;
                tokenize(line, toks);
                if (toks.size() == 0) continue;   // bos satir / sadece yorum
                parse_line(toks, line_no);
            end
            $fclose(fd);

            // Dosya sonu isareti: driver bunu gorunce "senaryo bitti" yazar.
            end_cmd = new(CMD_END, line_no);
            mbx.put(end_cmd);
            $display("[GEN] Senaryo dosyasi okundu: %s (%0d satir)", file_name, line_no);
        endtask

        // Tek satirin token'larina bakip komut turunu belirler.
        task parse_line(string toks[$], int line_no);
            bit [63:0]       t0;
            longint unsigned ns;
            scn_cmd          cmd;

            if (!parse_hex(toks[0], t0)) begin
                $error("[GEN] satir %0d: gecersiz ilk alan '%s' (hex bekleniyor), satir atlandi.",
                       line_no, toks[0]);
                return;
            end

            case (t0)
                // ---- HB bekle: arguman yok ----
                ADDR_WAIT_BEAM: begin
                    if (toks.size() > 1)
                        $warning("[GEN] satir %0d: 99999999 komutunda fazla alan yok sayildi.", line_no);
                    cmd = new(CMD_WAIT_BEAM, line_no);
                    mbx.put(cmd);
                end

                // ---- Zaman bekle / HB planla: arguman <ns> ----
                ADDR_WAIT_NS, ADDR_PLAN_BEAM: begin
                    if (toks.size() < 2 || !parse_dec(toks[1], ns)) begin
                        $error("[GEN] satir %0d: komutun ardindan sure (ns, onluk) bekleniyor, satir atlandi.",
                               line_no);
                        return;
                    end
                    cmd = new((t0 == ADDR_WAIT_NS) ? CMD_WAIT_NS : CMD_PLAN_BEAM, line_no);
                    cmd.ns = ns;
                    mbx.put(cmd);
                end

                // ---- Diger her sey: gercek TLP ----
                default: parse_tlp(toks, line_no, t0);
            endcase
        endtask

        // TLP satiri:  ADRES MSGID LEN BYTE0 BYTE1 ...
        task parse_tlp(string toks[$], int line_no, bit [63:0] address);
            bit [63:0]       mid;
            longint unsigned dlen;
            bit [63:0]       b;
            int              data_len;
            int              dword_count;
            int              total_tlp_bytes;
            bit [31:0]       msg_id;
            bit [7:0]        desc[16];
            tlp_item         tr;
            scn_cmd          cmd;

            if (toks.size() < 3 || !parse_hex(toks[1], mid) || !parse_dec(toks[2], dlen)) begin
                $error("[GEN] satir %0d: TLP satiri 'ADRES MSGID LEN DATA...' bicimde degil, atlandi.", line_no);
                return;
            end
            if ((mid >> 32) != 0 || dlen > 64'd8192) begin
                $error("[GEN] satir %0d: MSGID 32 bitten buyuk ya da LEN cok buyuk, atlandi.", line_no);
                return;
            end
            msg_id   = mid[31:0];
            data_len = int'(dlen);

            // Padding yok: veri uzunlugu 4'un kati olmali.
            if ((data_len % 4) != 0) begin
                $error("[GEN] satir %0d: LEN (%0d) 4'un kati degil, satir atlandi.", line_no, data_len);
                return;
            end
            // Bildirilen uzunluk kadar veri baytı olmali.
            if (toks.size() != (3 + data_len)) begin
                $error("[GEN] satir %0d: LEN=%0d ama %0d veri baytı var, satir atlandi.",
                       line_no, data_len, toks.size() - 3);
                return;
            end

            dword_count     = (4 + 4 + data_len) / 4;   // msg_id + length + payload
            total_tlp_bytes = 16 + 4 + 4 + data_len;
            if (dword_count > 1024)
                $warning("[GEN] satir %0d: DWORD sayisi %0d > 1024 (MPS/4KB siniri asilmis olabilir).",
                         line_no, dword_count);

            tr = new(total_tlp_bytes);
            tr.first_be = 4'b1111;
            tr.last_be  = 4'b1111;

            // ---- CQ descriptor (16 bayt, little-endian, AT=00) ----
            for (int i = 0; i < 16; i++) desc[i] = 8'h00;
            desc[0] = {address[7:2], 2'b00};
            desc[1] = address[15:8];
            desc[2] = address[23:16];
            desc[3] = address[31:24];
            desc[4] = address[39:32];
            desc[5] = address[47:40];
            desc[6] = address[55:48];
            desc[7] = address[63:56];
            desc[8] = dword_count[7:0];
            desc[9] = {1'b0, 4'b0001, dword_count[10:8]};   // req type = MemWr (0001)
            // TODO: requester id (10,11), tag (12), target fn (13), bar_id/aperture/TC/attr (14,15)
            for (int i = 0; i < 16; i++) tr.tlp_packet[i] = desc[i];

            // ---- msg_id ve length (little-endian) ----
            for (int i = 0; i < 4; i++) tr.tlp_packet[16 + i] = msg_id[8*i +: 8];
            for (int i = 0; i < 4; i++) tr.tlp_packet[20 + i] = data_len[8*i +: 8];

            // ---- payload ----
            for (int i = 0; i < data_len; i++) begin
                if (!parse_hex(toks[3 + i], b) || b > 64'hFF) begin
                    $error("[GEN] satir %0d: veri baytı '%s' gecersiz, satir atlandi.", line_no, toks[3 + i]);
                    return;
                end
                tr.tlp_packet[24 + i] = b[7:0];
            end

            cmd = new(CMD_TLP, line_no);
            cmd.tlp = tr;
            mbx.put(cmd);
            $display("[GEN] satir %0d: TLP -> Addr: %h | MsgID: %h | Len: %0d | TotalTLP: %0d byte",
                     line_no, address, msg_id, data_len, total_tlp_bytes);
        endtask
    endclass


    // =================================================================
    // beam_ctrl : huzme basi (HB) sinyalini izler ve (senaryo modunda) uretir
    //
    //  source = "SCRIPT" : HB'yi senaryo uretir. `77777777` komutu gen'de darbe verir.
    //  source = "DESIGN" : HB'yi tasarimdaki gercek modul uretir; `77777777` yok sayilir.
    //  `99999999` (wait_beam) her iki modda da obs'u izler.
    // =================================================================
    class beam_ctrl;
        virtual beam_if bif;
        string          source;       // "SCRIPT" | "DESIGN"
        int             pulse_clks;   // darbe genisligi (clock)
        bit             active_high;  // 1: aktif-yuksek darbe

        function new(virtual beam_if bif, string source = "SCRIPT",
                     int pulse_clks = 1, bit active_high = 1'b1);
            this.bif         = bif;
            this.source      = source;
            this.pulse_clks  = pulse_clks;
            this.active_high = active_high;
        endfunction

        // `ns` nanosaniye sonra HB darbesi uretmeyi planlar. BLOKLAMAZ:
        // darbe arka planda uretilir, driver bir sonraki komuta hemen gecer.
        task plan(longint unsigned ns);
            if (source != "SCRIPT") begin
                $warning("[BEAM] BEAM_SOURCE=%s iken 77777777 komutu yok sayildi (HB'yi tasarim uretiyor).", source);
                return;
            end
            fork
                pulse_after(ns);                     // arguman fork aninda kopyalanir
            join_none
        endtask

        // ns bekleyip tek bir HB darbesi uretir (plan() tarafindan arka planda cagrilir).
        task pulse_after(longint unsigned ns);
            #(ns);                                   // ns bekle (timescale 1ns)
            pulse();
        endtask

        // Tek bir HB darbesi uretir: saat kenarina hizalanir, pulse_clks clock tutar.
        task pulse();
            @(posedge bif.clk);
            bif.gen <= active_high;
            $display("[%0t] [BEAM] HB darbesi basladi", $time);
            repeat (pulse_clks) @(posedge bif.clk);
            bif.gen <= ~active_high;
        endtask

        // HB sinyalinin bir SONRAKI aktif kenarini bekler (gecmis darbeleri saymaz).
        task wait_beam();
            if (active_high) @(posedge bif.obs);
            else             @(negedge bif.obs);
        endtask
    endclass


    // =================================================================
    // driver : scn_cmd'leri sirayla calistirir
    //
    //  DATA_WIDTH  : AXI-S veri genisligi (bit)
    //  TUSER_WIDTH : >= 88 ise UltraScale+ CQ tuser duzeni, aksi halde basit duzen
    //  KEEP_GRAN   : tkeep bit basina bayt sayisi (1 veya 4)
    // =================================================================
    class driver #(int DATA_WIDTH = 256, int TUSER_WIDTH = 88, int KEEP_GRAN = 4);

        localparam int DATA_BYTES = DATA_WIDTH / 8;
        localparam int KEEP_WIDTH = DATA_BYTES / KEEP_GRAN;
        localparam bit US_PLUS_CQ = (TUSER_WIDTH >= 88);

        mailbox #(scn_cmd) mbx;
        virtual axis_tx_if #(DATA_WIDTH, TUSER_WIDTH, KEEP_GRAN) vif;
        beam_ctrl          beam;

        function new(virtual axis_tx_if #(DATA_WIDTH, TUSER_WIDTH, KEEP_GRAN) vif,
                     mailbox #(scn_cmd) mbx,
                     beam_ctrl beam);
            this.vif  = vif;
            this.mbx  = mbx;
            this.beam = beam;
        endfunction

        // Cikislari bosa ceker, reset (ve link up) kalkana kadar bekler.
        task reset();
            vif.tvalid <= 1'b0;
            vif.tdata  <= '0;
            vif.tlast  <= 1'b0;
            vif.tkeep  <= '0;
            vif.tuser  <= '0;
            wait (vif.rst_n === 1'b1);
            $display("[%0t] [DRIVER] Reset kalkti (DATA=%0d TUSER=%0d KEEP_GRAN=%0d)",
                     $time, DATA_WIDTH, TUSER_WIDTH, KEEP_GRAN);
        endtask

        // Mailbox'tan komut alip turune gore calistirir. Bekleme komutlari
        // sonraki komutlari bloklar; senaryo sirasi boylece korunur.
        task run();
            scn_cmd cmd;
            forever begin
                mbx.get(cmd);
                case (cmd.kind)
                    CMD_TLP: begin
                        drive_item(cmd.tlp);
                    end
                    CMD_WAIT_NS: begin
                        $display("[%0t] [DRIVER] satir %0d: %0d ns bekleniyor", $time, cmd.line_no, cmd.ns);
                        #(cmd.ns);
                        @(posedge vif.aclk);              // saat kenarina hizala
                    end
                    CMD_WAIT_BEAM: begin
                        $display("[%0t] [DRIVER] satir %0d: huzme basi bekleniyor", $time, cmd.line_no);
                        beam.wait_beam();
                        $display("[%0t] [DRIVER] huzme basi geldi", $time);
                        @(posedge vif.aclk);
                    end
                    CMD_PLAN_BEAM: begin
                        $display("[%0t] [DRIVER] satir %0d: %0d ns sonra huzme basi planlandi",
                                 $time, cmd.line_no, cmd.ns);
                        beam.plan(cmd.ns);                // bloklamaz
                    end
                    CMD_END: begin
                        $display("[%0t] [SCN] Senaryo bitti (simulasyonu TB sonlandirir).", $time);
                    end
                    default: $error("[DRIVER] bilinmeyen komut turu");
                endcase
            end
        endtask

        // tuser'i olusturur.
        //  US_PLUS_CQ : first_be[3:0], last_be[7:4], byte_en[39:8], sop[40] (ilk beat)
        //  basit duzen: ilk beat'te first_be, son beat'te last_be
        function automatic bit [TUSER_WIDTH-1:0] build_user(tlp_item msg, bit first_beat,
                                                            bit last_beat, int tlp_off, int n_bytes);
            bit [TUSER_WIDTH-1:0] user = '0;
            if (US_PLUS_CQ) begin
                // TODO: byte_en / parity duzenini PG213'ten dogrula.
                if (first_beat) begin
                    user[3:0] = msg.first_be;
                    user[7:4] = msg.last_be;
                    user[40]  = 1'b1;               // sop
                end
                for (int b = 0; b < n_bytes; b++)
                    if (tlp_off + b >= 16) user[8 + b] = 1'b1;   // sadece payload baytlari
            end else begin
                if (first_beat) user[3:0] = msg.first_be;
                if (last_beat)  user[7:4] = msg.last_be;
            end
            return user;
        endfunction

        // Bir TLP'yi beat'lere bolup AXI-S uzerinden surer (tready ile backpressure).
        task drive_item(tlp_item msg);
            bit [DATA_WIDTH-1:0] word;
            bit [KEEP_WIDTH-1:0] keep;
            int  total      = msg.tlp_packet.size();
            int  off        = 0;      // simdiye kadar gonderilen bayt sayisi
            int  n_bytes;
            bit  first_beat = 1'b1;
            bit  last_beat;

            @(posedge vif.aclk);
            while (off < total) begin
                n_bytes   = ((total - off) < DATA_BYTES) ? (total - off) : DATA_BYTES;
                last_beat = (off + n_bytes >= total);

                word = '0;
                keep = '0;
                for (int b = 0; b < n_bytes; b++) begin
                    word[b*8 +: 8]      = msg.tlp_packet[off + b];
                    keep[b / KEEP_GRAN] = 1'b1;
                end

                vif.tvalid <= 1'b1;
                vif.tdata  <= word;
                vif.tkeep  <= keep;
                vif.tlast  <= last_beat;
                vif.tuser  <= build_user(msg, first_beat, last_beat, off, n_bytes);

                @(posedge vif.aclk);
                if (vif.tready === 1'b1) begin   // beat kabul edildi
                    off += n_bytes;
                    first_beat = 1'b0;
                end
            end

            vif.tvalid <= 1'b0;
            vif.tlast  <= 1'b0;
            vif.tdata  <= '0;
            vif.tkeep  <= '0;
            vif.tuser  <= '0;
            $display("[%0t] [DRIVER] TLP surulduk (%0d byte)", $time, total);
        endtask
    endclass

endpackage
