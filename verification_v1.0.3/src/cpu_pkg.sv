`timescale 1ns / 1ps

// =====================================================================
// cpu_pkg : "Islemci" tarafi modeli  -  v1.0.3
//
// FPGA, PCIe uzerinden islemcinin hafizasina memory write TLP'leri gonderir
// (s_axis_rq portu). Bu paket, o TLP'leri alir, islemci hafizasina yazar,
// kesme (MSI) gelince circular buffer'dan mesajlari okuyup bir txt dosyasina yazar.
//
// Siniflar:
//   rq_pkt        : cozulmus bir RQ TLP'si (adres, tip, byte enable, payload)
//   rq_assembler  : RQ beat'lerini birlestirip rq_pkt uretir
//   cpu_mem       : seyrek (sparse), bayt adreslenebilir islemci hafizasi
//   cpu_buffer    : tek bir circular buffer'in tanimi (baslangic, boyut, pointer adresi)
//   cpu_model     : yazma yonlendirme + buffer programlama + ISR (kesme servis rutini)
//
// Bayt sirasi: tum cok baytli alanlar (konfigurasyon alanlari, pointer degeri,
// mesaj ID/len) VARSAYILAN olarak LITTLE-ENDIAN okunur (ilk bayt en dusuk anlamli).
// Derleme sirasi: axis_tx_if.sv -> beam_if.sv -> cpu_pkg.sv -> scn_pkg.sv -> sim_model_cpu.sv
// =====================================================================
package cpu_pkg;

    // RQ istek tipleri (descriptor DW2[14:11])
    localparam bit [3:0] REQ_TYPE_MEMRD = 4'b0000;
    localparam bit [3:0] REQ_TYPE_MEMWR = 4'b0001;

    // -----------------------------------------------------------------
    // Bayt dizisinin [off, off+n) araligini sayiya cevirir.
    // big_endian=0 : ilk bayt EN DUSUK anlamli (little-endian)
    // big_endian=1 : ilk bayt EN YUKSEK anlamli (yazildigi gibi)
    // -----------------------------------------------------------------
    function automatic bit [63:0] bytes_to_val(bit [7:0] b[], int off, int n, bit big_endian);
        bit [63:0] v = '0;
        for (int i = 0; i < n; i++) begin
            if (big_endian) v = (v << 8) | 64'(b[off + i]);
            else            v = v | (64'(b[off + i]) << (8 * i));
        end
        return v;
    endfunction


    // =================================================================
    // rq_pkt : cozulmus bir RQ TLP'si
    // =================================================================
    class rq_pkt;
        bit [63:0]   addr;       // DWORD hizali bayt adresi
        int unsigned dw_count;   // payload DWORD sayisi
        bit [3:0]    req_type;   // 0001 = MemWr, 0000 = MemRd
        bit [3:0]    first_be;   // ilk DWORD'un gecerli baytlari
        bit [3:0]    last_be;    // son DWORD'un gecerli baytlari
        bit [7:0]    payload[];  // payload baytlari (descriptor haric)
        longint      t_ns;       // paketin tamamlandigi zaman

        function string type_name();
            case (req_type)
                REQ_TYPE_MEMWR: return "MemWr";
                REQ_TYPE_MEMRD: return "MemRd";
                default:        return $sformatf("Tip%0b", req_type);
            endcase
        endfunction
    endclass


    // =================================================================
    // rq_assembler : s_axis_rq beat'lerini TLP'ye birlestirir
    //
    // Her kabul edilen beat (tvalid && tready) push_beat() ile verilir.
    // tlast gorulunce 16 baytlik descriptor cozulur ve rq_pkt doner.
    //  Descriptor (UltraScale+ RQ, 4 DWORD, little-endian):
    //    DW0: [31:2] adres[31:2]          DW1: adres[63:32]
    //    DW2: [10:0] DWORD sayisi, [14:11] istek tipi
    //  tuser: [3:0] first_be, [7:4] last_be (ilk beat'te gecerli)
    //  Payload, descriptor'in hemen arkasindan baslar (DWORD hizali mod).
    // =================================================================
    class rq_assembler;
        bit [7:0]    bytes[$];     // o ana kadar toplanan baytlar
        bit          collecting;   // bir TLP'nin ortasindayiz
        bit [3:0]    first_be;
        bit [3:0]    last_be;
        int unsigned bad_pkts;

        function new();
            collecting = 1'b0;
            bad_pkts   = 0;
        endfunction

        // Bir beat ekler. TLP tamamlandiysa 1 doner ve pkt dolar.
        function bit push_beat(bit [255:0] data, bit [7:0] keep, bit last,
                               bit [61:0] user, output rq_pkt pkt);
            pkt = null;
            if (!collecting) begin           // TLP'nin ilk beat'i
                collecting = 1'b1;
                bytes.delete();
                first_be = user[3:0];
                last_be  = user[7:4];
            end
            for (int d = 0; d < 8; d++)
                if (keep[d])
                    for (int i = 0; i < 4; i++)
                        bytes.push_back(data[32*d + 8*i +: 8]);
            if (!last) return 1'b0;
            collecting = 1'b0;
            pkt = decode();
            return (pkt != null);
        endfunction

        // Toplanan baytlari rq_pkt'ye cevirir.
        function rq_pkt decode();
            rq_pkt     p;
            bit [31:0] dw0, dw1, dw2;
            int        n_pay;
            if (bytes.size() < 16) begin
                $error("[RQ] TLP 16 bayttan kisa (%0d bayt), atildi.", bytes.size());
                bad_pkts++;
                return null;
            end
            dw0 = {bytes[3],  bytes[2],  bytes[1],  bytes[0]};
            dw1 = {bytes[7],  bytes[6],  bytes[5],  bytes[4]};
            dw2 = {bytes[11], bytes[10], bytes[9],  bytes[8]};
            p = new();
            p.addr     = {dw1, dw0[31:2], 2'b00};
            p.dw_count = dw2[10:0];
            p.req_type = dw2[14:11];
            p.first_be = first_be;
            p.last_be  = last_be;
            p.t_ns     = $time;
            n_pay = bytes.size() - 16;
            if (p.req_type == REQ_TYPE_MEMWR) begin
                if (n_pay != int'(p.dw_count) * 4)
                    $warning("[RQ] MemWr: descriptor %0d DWORD diyor ama %0d payload bayti geldi.",
                             p.dw_count, n_pay);
                p.payload = new[n_pay];
                for (int i = 0; i < n_pay; i++) p.payload[i] = bytes[16 + i];
            end else begin
                p.payload = new[0];
            end
            return p;
        endfunction
    endclass


    // =================================================================
    // cpu_mem : seyrek (sparse) bayt adreslenebilir hafiza
    //  Sadece yazilan adresler yer kaplar; boyut belirlemek gerekmez.
    //  Yazilmamis adres okunursa 0 doner ve sayac artar.
    // =================================================================
    class cpu_mem;
        bit [7:0]    mem[bit [63:0]];
        int unsigned uninit_reads;

        function new();
            uninit_reads = 0;
        endfunction

        function void write_byte(bit [63:0] a, bit [7:0] v);
            mem[a] = v;
        endfunction

        function bit [7:0] read_byte(bit [63:0] a);
            if (mem.exists(a)) return mem[a];
            uninit_reads++;
            return 8'h00;
        endfunction

        // n baytlik alani okur (n<=8). big_endian=0 -> little-endian.
        function bit [63:0] read_field(bit [63:0] a, int n, bit big_endian);
            bit [63:0] v = '0;
            for (int i = 0; i < n; i++) begin
                if (big_endian) v = (v << 8) | 64'(read_byte(a + i));
                else            v = v | (64'(read_byte(a + i)) << (8 * i));
            end
            return v;
        endfunction

        // 32 bit "satir" yukleme
        function bit [31:0] read32(bit [63:0] a, bit big_endian = 1'b0);
            bit [63:0] v = read_field(a, 4, big_endian);
            return v[31:0];
        endfunction

        // n baytlik alani degerle yazar
        function void write_field(bit [63:0] a, int n, bit [63:0] v, bit big_endian);
            for (int i = 0; i < n; i++) begin
                if (big_endian) write_byte(a + i, v[8*(n-1-i) +: 8]);
                else            write_byte(a + i, v[8*i +: 8]);
            end
        endfunction
    endclass


    // =================================================================
    // cpu_buffer : tek bir circular buffer'in tanimi
    // =================================================================
    class cpu_buffer;
        bit          valid;     // programlandi mi
        bit [63:0]   base;      // baslangic adresi
        bit [63:0]   size;      // boyut (bayt)
        bit [63:0]   ptr_addr;  // yazma pointer'inin tutuldugu bellek adresi
        bit [63:0]   last_ptr;  // islemcinin en son okudugu pointer (mutlak adres)

        function new();
            valid = 1'b0;
        endfunction

        function bit contains(bit [63:0] a);
            return valid && (a >= base) && (a < base + size);
        endfunction

        // pos'tan i bayt ileri adres; buffer sonunu gecince basa sarar
        function bit [63:0] ring_addr(bit [63:0] pos, bit [63:0] i);
            bit [63:0] a = pos + i;
            while (a >= base + size) a = a - size;
            return a;
        endfunction
    endclass


    // =================================================================
    // cpu_model : islemci
    //
    //  program_from_tlp() : CPU->FPGA konfigurasyon mesajindan buffer'i kurar
    //  on_pkt()           : FPGA'dan gelen memory write'i hafizaya yazar
    //  run_isr()          : kesme servis rutini; yeni mesajlari okuyup dosyaya yazar
    // =================================================================
    class cpu_model;
        cpu_mem      mem;
        cpu_buffer   buffer;
        string       out_file;
        string       trace_file;
        int          out_fd;
        int          trace_fd;

        // Bayt sirasi ayarlari (0: little-endian, 1: yazildigi gibi/big-endian)
        bit          cfg_be;   // konfigurasyon alanlari (base/size/ptr_addr)
        bit          ptr_be;   // pointer degeri
        bit          msg_be;   // buffer'daki mesajlarin ID/len alanlari

        bit [31:0]   cfg_msg_id;  // buffer'i programlayan mesajin ID'si
        int          ptr_width;   // pointer degerinin bayt sayisi (4 veya 8, yazimdan ogrenilir)

        // Sayaclar (testler ve rapor icin)
        int unsigned tlp_count;
        int unsigned msg_count;
        int unsigned isr_count;
        int unsigned spurious_isr;
        int unsigned wrap_events;
        int unsigned ptr_updates;
        int unsigned error_count;

        function new(string out_file = "cpu_out.txt", string trace_file = "rq_trace.txt",
                     bit cfg_be = 1'b0, bit ptr_be = 1'b0, bit msg_be = 1'b0,
                     bit [31:0] cfg_msg_id = 32'h1DEA0001);
            this.mem        = new();
            this.buffer     = new();
            this.out_file   = out_file;
            this.trace_file = trace_file;
            this.cfg_be     = cfg_be;
            this.ptr_be     = ptr_be;
            this.msg_be     = msg_be;
            this.cfg_msg_id = cfg_msg_id;
            this.ptr_width  = 8;
            this.tlp_count = 0; this.msg_count = 0; this.isr_count = 0;
            this.spurious_isr = 0; this.wrap_events = 0; this.ptr_updates = 0; this.error_count = 0;
            out_fd   = $fopen(out_file, "w");
            trace_fd = $fopen(trace_file, "w");
            if (out_fd == 0)   $fatal(1, "[CPU] cikti dosyasi acilamadi: %s", out_file);
            if (trace_fd == 0) $fatal(1, "[CPU] iz dosyasi acilamadi: %s", trace_file);
        endfunction

        // ------------------------------------------------------------
        // Buffer programlama
        // ------------------------------------------------------------

        // CPU->FPGA yonunde giden bir TLP konfigurasyon mesajiysa (ID eslesirse) buffer'i kurar.
        // pkt: scn_pkg::tlp_item.tlp_packet (16B descriptor + 4B ID + 4B len + veri)
        function void maybe_program(bit [7:0] pkt[]);
            bit [63:0] id;
            if (pkt.size() < 24) return;
            id = bytes_to_val(pkt, 16, 4, 1'b0);   // ID: CPU->FPGA yonunde little-endian
            if (id[31:0] != cfg_msg_id) return;
            program_from_tlp(pkt);
        endfunction

        // Veri alani: [0..7] baslangic adresi, [8..15] boyut, [16..23] pointer adresi
        // (veri, TLP'nin 24. baytindan baslar). Sonrasi yok sayilir.
        function void program_from_tlp(bit [7:0] pkt[]);
            bit [63:0] b, s, p;
            if (pkt.size() < 24 + 24) begin
                $error("[CPU] konfigurasyon mesaji en az 24 veri bayti icermeli (%0d var).", pkt.size() - 24);
                error_count++;
                return;
            end
            b = bytes_to_val(pkt, 24, 8, cfg_be);
            s = bytes_to_val(pkt, 32, 8, cfg_be);
            p = bytes_to_val(pkt, 40, 8, cfg_be);
            if (s == 0 || (s % 4) != 0) begin
                $error("[CPU] gecersiz buffer boyutu: %0d (0 veya 4'un kati degil).", s);
                error_count++;
                return;
            end
            if (p >= b && p < b + s)
                $warning("[CPU] pointer adresi (%h) buffer icinde kaliyor.", p);
            buffer.base     = b;
            buffer.size     = s;
            buffer.ptr_addr = p;
            buffer.last_ptr = b;
            buffer.valid    = 1'b1;
            ptr_width       = 8;
            // Islemci pointer bolgesini baslangic degeriyle hazirlar (pointer = buffer basi)
            mem.write_field(p, 8, b, ptr_be);
            $display("[%0t] [CPU] buffer programlandi: base=%h size=%0d ptr_adresi=%h", $time, b, s, p);
            $fdisplay(trace_fd, "[%0t] CFG base=%h size=%0d ptr_addr=%h", $time, b, s, p);
            $fflush(trace_fd);   // iz dosyasi simulasyon acikken de okunabilsin
        endfunction

        // ------------------------------------------------------------
        // FPGA'dan gelen TLP
        // ------------------------------------------------------------
        function void on_pkt(rq_pkt p);
            bit        crossed = 1'b0;
            bit        start_in_buf;
            bit [3:0]  mask;
            bit [63:0] a;
            bit [63:0] pv;
            tlp_count++;
            $fdisplay(trace_fd, "[%0t] RQ %s addr=%h dw=%0d first_be=%b last_be=%b",
                      $time, p.type_name(), p.addr, p.dw_count, p.first_be, p.last_be);
            $fflush(trace_fd);   // iz dosyasi simulasyon acikken de okunabilsin

            if (p.req_type != REQ_TYPE_MEMWR) begin
                $warning("[CPU] %s desteklenmiyor (FPGA'nin sadece MemWr gondermesi bekleniyor), atildi.",
                         p.type_name());
                return;
            end
            if (p.payload.size() == 0) return;
            if (!buffer.valid)
                $warning("[CPU] buffer programlanmadan yazma geldi (addr=%h), hafizaya yazildi.", p.addr);

            start_in_buf = buffer.contains(p.addr);
            if (buffer.valid && !start_in_buf &&
                !(p.addr >= buffer.ptr_addr && p.addr < buffer.ptr_addr + 8))
                $warning("[CPU] yazma buffer disinda (addr=%h), hafizaya yazildi.", p.addr);

            for (int d = 0; d < int'(p.dw_count) && (d * 4 + 3) < p.payload.size(); d++) begin
                mask = 4'hF;
                if (d == 0)                          mask = p.first_be;
                else if (d == int'(p.dw_count) - 1)  mask = p.last_be;
                for (int k = 0; k < 4; k++) begin
                    if (!mask[k]) continue;
                    a = p.addr + d * 4 + k;
                    // Buffer icinden baslayip sonunu asan yazma: tasan kismi basa sar
                    if (start_in_buf && a >= buffer.base + buffer.size) begin
                        a = a - buffer.size;
                        crossed = 1'b1;
                    end
                    mem.write_byte(a, p.payload[d * 4 + k]);
                end
            end

            if (crossed) begin
                wrap_events++;
                $warning("[CPU] TLP buffer sonunu asti (addr=%h), tasan kisim basa sarildi.", p.addr);
                $fdisplay(trace_fd, "[%0t]   !! buffer sonu asildi, basa sarildi", $time);
                $fflush(trace_fd);   // iz dosyasi simulasyon acikken de okunabilsin
            end

            // Pointer bolgesine yazildiysa degeri ogren ve kaydet
            if (buffer.valid && p.addr == buffer.ptr_addr) begin
                ptr_width = (p.dw_count >= 2) ? 8 : 4;
                ptr_updates++;
                pv = mem.read_field(buffer.ptr_addr, ptr_width, ptr_be);
                $fdisplay(trace_fd, "[%0t]   pointer guncellendi: %h (%0d bayt)", $time, pv, ptr_width);
                $fflush(trace_fd);   // iz dosyasi simulasyon acikken de okunabilsin
            end
        endfunction

        // ------------------------------------------------------------
        // ISR : kesme servis rutini
        //  1) pointer'i oku  2) last_ptr ile arasini mesajlara bol  3) dosyaya yaz
        // ------------------------------------------------------------
        function void run_isr();
            bit [63:0]   newp, pos;
            bit [63:0]   avail, consumed, total;
            bit [63:0]   id, len;
            bit [7:0]    data[];
            int unsigned nmsg = 0;

            isr_count++;
            if (!buffer.valid) begin
                $warning("[CPU] kesme geldi ama buffer programlanmamis.");
                return;
            end

            newp = mem.read_field(buffer.ptr_addr, ptr_width, ptr_be);
            if (newp == buffer.base + buffer.size) newp = buffer.base;   // sonu = basi
            if (!buffer.contains(newp)) begin
                $error("[CPU] pointer buffer disinda: %h (buffer %h..%h).",
                       newp, buffer.base, buffer.base + buffer.size);
                error_count++;
                return;
            end
            if (newp == buffer.last_ptr) begin
                spurious_isr++;
                $fdisplay(trace_fd, "[%0t] ISR #%0d: yeni veri yok (pointer=%h)", $time, isr_count, newp);
                $fflush(trace_fd);   // iz dosyasi simulasyon acikken de okunabilsin
                return;
            end

            avail    = (newp > buffer.last_ptr) ? (newp - buffer.last_ptr)
                                                : (newp + buffer.size - buffer.last_ptr);
            pos      = buffer.last_ptr;
            consumed = 0;

            while (consumed < avail) begin
                if (avail - consumed < 8) begin
                    $error("[CPU] %0d bayt kaldi, mesaj basligina (8 bayt) yetmiyor.", avail - consumed);
                    error_count++;
                    break;
                end
                id  = ring_field(pos, 0, 4, msg_be);
                len = ring_field(pos, 4, 4, msg_be);
                total = 8 + len;
                if (len > buffer.size || consumed + total > avail) begin
                    $error("[CPU] mesaj yarim ya da len uyusmuyor: id=%h len=%0d kalan=%0d",
                           id[31:0], len, avail - consumed);
                    error_count++;
                    break;
                end
                data = new[int'(len)];
                for (int i = 0; i < int'(len); i++)
                    data[i] = mem.read_byte(buffer.ring_addr(pos, 8 + i));
                write_msg(id[31:0], int'(len), data);
                nmsg++;
                msg_count++;
                consumed += total;
                pos = buffer.ring_addr(pos, total);
            end

            buffer.last_ptr = pos;
            $display("[%0t] [CPU] ISR #%0d: %0d mesaj okundu (pointer=%h)", $time, isr_count, nmsg, newp);
            $fdisplay(trace_fd, "[%0t] ISR #%0d: pointer=%h, %0d mesaj okundu, last_ptr=%h",
                      $time, isr_count, newp, nmsg, buffer.last_ptr);
            $fflush(trace_fd);   // iz dosyasi simulasyon acikken de okunabilsin
        endfunction

        // pos'tan itibaren (off. bayttan) n baytlik alani, buffer sarmasiyla okur
        function bit [63:0] ring_field(bit [63:0] pos, int off, int n, bit big_endian);
            bit [63:0] v = '0;
            bit [7:0]  by;
            for (int i = 0; i < n; i++) begin
                by = mem.read_byte(buffer.ring_addr(pos, off + i));
                if (big_endian) v = (v << 8) | 64'(by);
                else            v = v | (64'(by) << (8 * i));
            end
            return v;
        endfunction

        // Cikti dosyasina bir mesaj yazar:  MSGID LEN BYTE0 BYTE1 ...
        function void write_msg(bit [31:0] id, int len, bit [7:0] data[]);
            $fwrite(out_fd, "%08X %0d", id, len);
            foreach (data[i]) $fwrite(out_fd, " %02X", data[i]);
            $fwrite(out_fd, "\n");
            $fflush(out_fd);
        endfunction

        function void report();
            $display("[CPU] ozet: tlp=%0d mesaj=%0d isr=%0d (sahte=%0d) sarma=%0d pointer_yazimi=%0d hata=%0d",
                     tlp_count, msg_count, isr_count, spurious_isr, wrap_events, ptr_updates, error_count);
        endfunction
    endclass

endpackage
