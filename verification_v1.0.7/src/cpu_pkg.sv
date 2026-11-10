`timescale 1ns / 1ps

// =====================================================================
// cpu_pkg : "Islemci" tarafi modeli  -  v1.0.7
//
// FPGA, PCIe uzerinden islemcinin hafizasina memory write TLP'leri gonderir
// (s_axis_rq portu). Bu paket, o TLP'leri alir, islemci hafizasina yazar,
// kesme (MSI) gelince circular buffer'dan mesajlari okuyup bir txt dosyasina yazar.
//
// Siniflar:
//   rq_pkt        : cozulmus bir RQ TLP'si (adres, tip, byte enable, payload)
//   rq_assembler  : RQ beat'lerini birlestirip rq_pkt uretir
//   cpu_mem       : seyrek (sparse), bayt adreslenebilir islemci hafizasi
//   cpu_buffer    : tek bir circular buffer'in tanimi + durumu (baslangic, boyut, pointer, cikti dosyasi)
//   cpu_model     : 4 buffer (SIFPGA/SHOB1/SHOB2/IUB), yazma yonlendirme, programlama, vektor tabanli ISR
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


    // Buffer indeksleri (MSI vektor bit numaralariyla AYNI)
    localparam int NBUF        = 4;
    localparam int BUF_SIFPGA  = 0;
    localparam int BUF_SHOB1   = 1;
    localparam int BUF_SHOB2   = 2;
    localparam int BUF_IUB     = 3;
    localparam int MSI_RSI_A   = 4;   // RSI: henuz uygulanmadi
    localparam int MSI_RSI_B   = 5;   // RSI: henuz uygulanmadi

    function automatic string buf_name(int i);
        case (i)
            BUF_SIFPGA: return "sifpga";
            BUF_SHOB1:  return "shob1";
            BUF_SHOB2:  return "shob2";
            BUF_IUB:    return "iub";
            default:    return $sformatf("buf%0d", i);
        endcase
    endfunction


    // =================================================================
    // cpu_buffer : tek bir circular buffer'in tanimi ve calisma durumu
    // =================================================================
    class cpu_buffer;
        string       name;      // "sifpga", "shob1", ...
        bit          valid;     // programlandi mi (size=0 -> devre disi)
        bit [63:0]   base;      // baslangic adresi
        bit [63:0]   size;      // boyut (bayt)
        bit [63:0]   ptr_addr;  // yazma pointer'inin tutuldugu bellek adresi
        bit [63:0]   last_ptr;  // islemcinin en son okudugu pointer (mutlak adres)
        int          ptr_width; // pointer degerinin bayt sayisi (4 veya 8, yazimdan ogrenilir)
        longint unsigned unread_bytes;  // yazilmis ama ISR'nin henuz okumadigi bayt
        bit          overrun_flag;      // tasma devam ediyor (ayni olayi tekrar saymamak icin)
        string       out_file;
        int          out_fd;

        // buffer basina sayaclar
        int unsigned msg_count;
        int unsigned ptr_updates;
        int unsigned overrun_count;
        int unsigned isr_count;

        function new(string name, string out_file);
            this.name     = name;
            this.out_file = out_file;
            valid = 1'b0; ptr_width = 8; unread_bytes = 0; overrun_flag = 1'b0;
            msg_count = 0; ptr_updates = 0; overrun_count = 0; isr_count = 0;
            out_fd = $fopen(out_file, "w");
            if (out_fd == 0) $fatal(1, "[CPU] cikti dosyasi acilamadi: %s", out_file);
        endfunction

        function bit contains(bit [63:0] a);
            return valid && (a >= base) && (a < base + size);
        endfunction

        function bit in_ptr(bit [63:0] a);
            return valid && (a >= ptr_addr) && (a < ptr_addr + 8);
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
    //  maybe_program()/program_from_tlp() : CPU->FPGA 1DEA0001 mesajindan 4 buffer'i kurar
    //      veri baytlari: [0..23] SIFPGA, [24..47] SHOB1, [48..71] SHOB2, [72..95] IUB
    //      her biri: base(8B) size(8B) ptr_addr(8B), little-endian; size=0 -> buffer kapali
    //  on_pkt()  : FPGA'dan gelen memory write'i adrese gore hafizaya yazar
    //  run_isr(mask) : MSI vektorunde set olan bitlerin buffer'larini okuyup ayri dosyalara yazar
    // =================================================================
    class cpu_model;
        cpu_mem      mem;
        cpu_buffer   buffers[NBUF];
        string       trace_file;
        int          trace_fd;

        // Bayt sirasi ayarlari (0: little-endian, 1: yazildigi gibi/big-endian)
        bit          cfg_be;   // konfigurasyon alanlari (base/size/ptr_addr)
        bit          ptr_be;   // pointer degeri
        bit          msg_be;   // buffer'daki mesajlarin ID/len alanlari

        bit [31:0]   cfg_msg_id;  // buffer'lari programlayan mesajin ID'si

        // Genel sayaclar (testler ve rapor icin)
        int unsigned tlp_count;
        int unsigned msg_count;
        int unsigned isr_count;
        int unsigned spurious_isr;
        int unsigned wrap_events;
        int unsigned ptr_updates;
        int unsigned error_count;
        int unsigned overrun_count;
        int unsigned unknown_msi;   // bit 7..31 ile gelen (tanimsiz) kesmeler
        int unsigned msi7_count;    // v1.0.7: bit 6 = MSI7 (SIFPGA adres atama sonrasi RSY kesmesi)
        int unsigned rsi_ignored;    // RSI bitleri (4,5) ile gelen ve yok sayilan kesmeler
        int unsigned stray_writes;   // hicbir buffer'a / pointer bolgesine denk dusmeyen yazimlar

        function new(string out_prefix = "cpu_out", string trace_file = "rq_trace.txt",
                     bit cfg_be = 1'b0, bit ptr_be = 1'b0, bit msg_be = 1'b0,
                     bit [31:0] cfg_msg_id = 32'h1DEA0001);
            this.mem        = new();
            this.trace_file = trace_file;
            this.cfg_be     = cfg_be;
            this.ptr_be     = ptr_be;
            this.msg_be     = msg_be;
            this.cfg_msg_id = cfg_msg_id;
            for (int i = 0; i < NBUF; i++)
                buffers[i] = new(buf_name(i), {out_prefix, "_", buf_name(i), ".txt"});
            this.tlp_count = 0; this.msg_count = 0; this.isr_count = 0;
            this.spurious_isr = 0; this.wrap_events = 0; this.ptr_updates = 0; this.error_count = 0;
            this.overrun_count = 0; this.rsi_ignored = 0; this.unknown_msi = 0; this.msi7_count = 0; this.stray_writes = 0;
            trace_fd = $fopen(trace_file, "w");
            if (trace_fd == 0) $fatal(1, "[CPU] iz dosyasi acilamadi: %s", trace_file);
        endfunction

        function void trace(string s);
            $fdisplay(trace_fd, "[%0t] %s", $time, s);
            $fflush(trace_fd);   // iz dosyasi simulasyon acikken de okunabilsin
        endfunction

        // ------------------------------------------------------------
        // Buffer programlama
        // ------------------------------------------------------------

        // CPU->FPGA yonunde giden bir TLP konfigurasyon mesajiysa (ID eslesirse) buffer'lari kurar.
        // pkt: scn_pkg::tlp_item.tlp_packet (16B descriptor + 4B ID + 4B len + veri)
        function void maybe_program(bit [7:0] pkt[]);
            bit [63:0] id;
            if (pkt.size() < 24) return;
            id = bytes_to_val(pkt, 16, 4, 1'b0);   // ID: CPU->FPGA yonunde little-endian
            if (id[31:0] != cfg_msg_id) return;
            program_from_tlp(pkt);
        endfunction

        // Veri, TLP'nin 24. baytindan baslar. Her buffer icin 24 bayt gerekir; mesaj kisaysa
        // kalan buffer'lar programlanmaz (kapali kalir). Fazla baytlar yok sayilir.
        function void program_from_tlp(bit [7:0] pkt[]);
            bit [63:0] b, s, p;
            int        off;
            int        n_prog = 0;
            if (pkt.size() < 24 + 24) begin
                $error("[CPU] konfigurasyon mesaji en az 24 veri bayti icermeli (%0d var).", pkt.size() - 24);
                error_count++;
                return;
            end
            for (int i = 0; i < NBUF; i++) begin
                off = 24 + 24 * i;
                buffers[i].valid = 1'b0;
                if (pkt.size() < off + 24) continue;
                b = bytes_to_val(pkt, off,      8, cfg_be);
                s = bytes_to_val(pkt, off + 8,  8, cfg_be);
                p = bytes_to_val(pkt, off + 16, 8, cfg_be);
                if (s == 0) begin
                    $display("[%0t] [CPU] %s: size=0, buffer kapali.", $time, buffers[i].name);
                    trace($sformatf("CFG %s kapali (size=0)", buffers[i].name));
                    continue;
                end
                if ((s % 4) != 0) begin
                    $error("[CPU] %s: gecersiz buffer boyutu %0d (4'un kati degil).", buffers[i].name, s);
                    error_count++;
                    continue;
                end
                if (p >= b && p < b + s)
                    $warning("[CPU] %s: pointer adresi (%h) buffer icinde kaliyor.", buffers[i].name, p);
                buffers[i].base         = b;
                buffers[i].size         = s;
                buffers[i].ptr_addr     = p;
                buffers[i].last_ptr     = b;
                buffers[i].valid        = 1'b1;
                buffers[i].ptr_width    = 8;
                buffers[i].unread_bytes = 0;
                buffers[i].overrun_flag = 1'b0;
                // Islemci pointer bolgesini baslangic degeriyle hazirlar (pointer = buffer basi)
                mem.write_field(p, 8, b, ptr_be);
                n_prog++;
                $display("[%0t] [CPU] %s programlandi: base=%h size=%0d ptr_adresi=%h",
                         $time, buffers[i].name, b, s, p);
                trace($sformatf("CFG %s base=%h size=%0d ptr_addr=%h", buffers[i].name, b, s, p));
            end
            // Ust uste binen buffer/pointer araliklari icin uyari
            for (int i = 0; i < NBUF; i++)
                for (int j = i + 1; j < NBUF; j++)
                    if (buffers[i].valid && buffers[j].valid &&
                        buffers[i].base < buffers[j].base + buffers[j].size &&
                        buffers[j].base < buffers[i].base + buffers[i].size)
                        $warning("[CPU] %s ve %s buffer'lari ust uste biniyor.",
                                 buffers[i].name, buffers[j].name);
        endfunction

        // Adresin dustugu buffer (veri penceresi); yoksa -1
        function int find_data_buf(bit [63:0] a);
            for (int i = 0; i < NBUF; i++) if (buffers[i].contains(a)) return i;
            return -1;
        endfunction

        // Adres bir pointer bolgesinin basina esitse o buffer; yoksa -1
        function int find_ptr_buf(bit [63:0] a);
            for (int i = 0; i < NBUF; i++) if (buffers[i].valid && a == buffers[i].ptr_addr) return i;
            return -1;
        endfunction

        // ------------------------------------------------------------
        // FPGA'dan gelen TLP
        // ------------------------------------------------------------
        function void on_pkt(rq_pkt p);
            bit        crossed = 1'b0;
            int        bi, pi, wi;
            bit [3:0]  mask;
            bit [63:0] a;
            bit [63:0] pv;
            cpu_buffer bf;
            tlp_count++;
            trace($sformatf("RQ %s addr=%h dw=%0d first_be=%b last_be=%b",
                            p.type_name(), p.addr, p.dw_count, p.first_be, p.last_be));

            if (p.req_type != REQ_TYPE_MEMWR) begin
                $warning("[CPU] %s desteklenmiyor (FPGA'nin sadece MemWr gondermesi bekleniyor), atildi.",
                         p.type_name());
                return;
            end
            if (p.payload.size() == 0) return;

            bi = find_data_buf(p.addr);
            pi = find_ptr_buf(p.addr);
            bf = (bi >= 0) ? buffers[bi] : null;
            if (bi < 0 && pi < 0) begin
                stray_writes++;
                $warning("[CPU] yazma hicbir buffer/pointer bolgesine denk dusmuyor (addr=%h), hafizaya yazildi.", p.addr);
                trace($sformatf("  !! buffer disi yazma addr=%h", p.addr));
            end

            for (int d = 0; d < int'(p.dw_count) && (d * 4 + 3) < p.payload.size(); d++) begin
                mask = 4'hF;
                if (d == 0)                          mask = p.first_be;
                else if (d == int'(p.dw_count) - 1)  mask = p.last_be;
                for (int k = 0; k < 4; k++) begin
                    if (!mask[k]) continue;
                    a = p.addr + d * 4 + k;
                    // Buffer icinden baslayip sonunu asan yazma: tasan kismi basa sar
                    if (bf != null && a >= bf.base + bf.size) begin
                        a = a - bf.size;
                        crossed = 1'b1;
                    end
                    mem.write_byte(a, p.payload[d * 4 + k]);
                    wi = find_data_buf(a);
                    if (wi >= 0) buffers[wi].unread_bytes++;
                end
            end

            // Okunmamis veri buffer boyutunu astiysa FPGA, islemcinin okumadigi verinin ustune yaziyordur
            for (int i = 0; i < NBUF; i++) begin
                bf = buffers[i];
                if (!bf.valid) continue;
                if (bf.unread_bytes > bf.size && !bf.overrun_flag) begin
                    bf.overrun_flag = 1'b1;
                    bf.overrun_count++;
                    overrun_count++;
                    $warning("[CPU] %s BUFFER TASTI: okunmamis %0d bayt > buffer boyutu %0d (eski veri ustune yazildi).",
                             bf.name, bf.unread_bytes, bf.size);
                    trace($sformatf("  !! %s BUFFER TASTI: okunmamis=%0d boyut=%0d", bf.name, bf.unread_bytes, bf.size));
                end else if (bf.unread_bytes <= bf.size) begin
                    bf.overrun_flag = 1'b0;
                end
            end

            if (crossed) begin
                wrap_events++;
                $warning("[CPU] TLP buffer sonunu asti (addr=%h), tasan kisim basa sarildi.", p.addr);
                trace("  !! buffer sonu asildi, basa sarildi");
            end

            // Pointer bolgesine yazildiysa degeri ogren ve kaydet
            if (pi >= 0) begin
                bf = buffers[pi];
                bf.ptr_width = (p.dw_count >= 2) ? 8 : 4;
                bf.ptr_updates++;
                ptr_updates++;
                pv = mem.read_field(bf.ptr_addr, bf.ptr_width, ptr_be);
                trace($sformatf("  %s pointer guncellendi: %h (%0d bayt)", bf.name, pv, bf.ptr_width));
            end
        endfunction

        // ------------------------------------------------------------
        // ISR : kesme servis rutini
        //  vec: MSI vektoru (bit i = buffer i; bit4/5 = RSI, yok sayilir)
        //  Her set bit icin: 1) pointer'i oku  2) last_ptr ile arasini mesajlara bol  3) dosyaya yaz
        // ------------------------------------------------------------
        function void run_isr(bit [31:0] vec);
            isr_count++;
            trace($sformatf("ISR #%0d vektor=%h (bit6..0=%b)", isr_count, vec, vec[6:0]));
            if (vec[6]) begin   // MSI7 (0b1000000): SIFPGA adres atama (1DEA0001) sonrasi RSY kesmesi
                msi7_count++;
                $display("[%0t] [CPU] MSI7 (bit 6): SIFPGA adres atama kesmesi (okunacak buffer yok).", $time);
                trace("  MSI7 (bit 6): SIFPGA adres atama kesmesi");
            end
            if (vec[31:7] != 0) begin
                unknown_msi++;
                $warning("[CPU] MSI vektorunde tanimsiz bit(ler) var: %h (bit 7..31 kullanilmiyor).", vec);
                trace($sformatf("  !! tanimsiz MSI bitleri: %h", vec & 32'hFFFF_FF80));
            end
            for (int i = 0; i < NBUF; i++)
                if (vec[i]) run_isr_buf(i);
            if (vec[MSI_RSI_A] || vec[MSI_RSI_B]) begin
                rsi_ignored++;
                $display("[%0t] [CPU] RSI kesmesi (vektor=%b): henuz uygulanmadi, yok sayildi.", $time, vec[5:0]);
                trace("  RSI kesmesi henuz uygulanmadi");
            end
        endfunction

        function void run_isr_buf(int bi);
            cpu_buffer   bf = buffers[bi];
            bit [63:0]   newp, pos;
            bit [63:0]   avail, consumed, total;
            bit [63:0]   id, len;
            bit [7:0]    data[];
            int unsigned nmsg = 0;

            bf.isr_count++;
            if (!bf.valid) begin
                $warning("[CPU] %s icin kesme geldi ama buffer programlanmamis/kapali.", bf.name);
                return;
            end

            newp = mem.read_field(bf.ptr_addr, bf.ptr_width, ptr_be);
            if (newp == bf.base + bf.size) newp = bf.base;   // sonu = basi
            if (!bf.contains(newp)) begin
                $error("[CPU] %s: pointer buffer disinda: %h (buffer %h..%h).",
                       bf.name, newp, bf.base, bf.base + bf.size);
                error_count++;
                return;
            end
            if (newp == bf.last_ptr) begin
                spurious_isr++;
                trace($sformatf("  %s: yeni veri yok (pointer=%h)", bf.name, newp));
                return;
            end

            avail    = (newp > bf.last_ptr) ? (newp - bf.last_ptr)
                                            : (newp + bf.size - bf.last_ptr);
            pos      = bf.last_ptr;
            consumed = 0;

            while (consumed < avail) begin
                if (avail - consumed < 8) begin
                    $error("[CPU] %s: %0d bayt kaldi, mesaj basligina (8 bayt) yetmiyor.", bf.name, avail - consumed);
                    error_count++;
                    break;
                end
                id  = ring_field(bf, pos, 0, 4, msg_be);
                len = ring_field(bf, pos, 4, 4, msg_be);
                total = 8 + len;
                if (len > bf.size || consumed + total > avail) begin
                    $error("[CPU] %s: mesaj yarim ya da len uyusmuyor: id=%h len=%0d kalan=%0d",
                           bf.name, id[31:0], len, avail - consumed);
                    error_count++;
                    break;
                end
                data = new[int'(len)];
                for (int i = 0; i < int'(len); i++)
                    data[i] = mem.read_byte(bf.ring_addr(pos, 8 + i));
                write_msg(bf, id[31:0], int'(len), data);
                nmsg++;
                bf.msg_count++;
                msg_count++;
                consumed += total;
                pos = bf.ring_addr(pos, total);
            end

            bf.last_ptr = pos;
            if (consumed >= bf.unread_bytes) bf.unread_bytes = 0;
            else                             bf.unread_bytes = bf.unread_bytes - consumed;
            $display("[%0t] [CPU] %s: %0d mesaj okundu (pointer=%h)", $time, bf.name, nmsg, newp);
            trace($sformatf("  %s: pointer=%h, %0d mesaj okundu, last_ptr=%h", bf.name, newp, nmsg, bf.last_ptr));
        endfunction

        // pos'tan itibaren (off. bayttan) n baytlik alani, buffer sarmasiyla okur
        function bit [63:0] ring_field(cpu_buffer bf, bit [63:0] pos, int off, int n, bit big_endian);
            bit [63:0] v = '0;
            bit [7:0]  by;
            for (int i = 0; i < n; i++) begin
                by = mem.read_byte(bf.ring_addr(pos, off + i));
                if (big_endian) v = (v << 8) | 64'(by);
                else            v = v | (64'(by) << (8 * i));
            end
            return v;
        endfunction

        // Buffer'in cikti dosyasina bir mesaj yazar:  MSGID LEN BYTE0 BYTE1 ...
        function void write_msg(cpu_buffer bf, bit [31:0] id, int len, bit [7:0] data[]);
            $fwrite(bf.out_fd, "%08X %0d", id, len);
            foreach (data[i]) $fwrite(bf.out_fd, " %02X", data[i]);
            $fwrite(bf.out_fd, "\n");
            $fflush(bf.out_fd);
        endfunction

        function void report();
            $display("[CPU] ozet: tlp=%0d mesaj=%0d isr=%0d (sahte=%0d) sarma=%0d pointer_yazimi=%0d tasma=%0d rsi=%0d buffer_disi=%0d hata=%0d",
                     tlp_count, msg_count, isr_count, spurious_isr, wrap_events, ptr_updates, overrun_count,
                     rsi_ignored, stray_writes, error_count);
            for (int i = 0; i < NBUF; i++)
                $display("[CPU]   %-6s: %s mesaj=%0d pointer_yazimi=%0d tasma=%0d",
                         buffers[i].name, buffers[i].valid ? "acik " : "kapali",
                         buffers[i].msg_count, buffers[i].ptr_updates, buffers[i].overrun_count);
        endfunction
    endclass

    // =================================================================
    // v1.0.7: RSI ortak durumu
    //
    // CPU VIP'in senaryo surucusu, FPGA'ya giden iki konfigurasyon mesajini dinler:
    //   1DEA0001 (PCIe adres atama)  : veri[96..119] = RSI1/RSI2/RSI3 veri baslangic adresleri (3 x 8 B)
    //   1DEA0003 (SIFPGA huzpar)     : RSI offset'leri, huzme ID, huzme/darbe/ornek sayisi, RSI basina huzme sayisi
    // RSI modelleri (sim_model_rsi) bu bilgiyi buradan okur (ayni simulasyon icinde paylasilan paket degiskenleri).
    // Her 1DEA0003 bir "tur"dur; RSI'ler turlari sirayla tuketir (her MSI1/MSI2 bir turu kapatir).
    // =================================================================
    localparam int NRSI = 3;
    localparam bit [31:0] ID_ADRES_ATAMA   = 32'h1DEA0001;
    localparam bit [31:0] ID_SIFPGA_HUZPAR = 32'h1DEA0003;

    bit [63:0] rsi_start_addr [1:3];       // RSI veri baslangic adresleri (1DEA0001)
    bit        rsi_start_valid = 1'b0;

    class huzme_tur;
        bit [63:0]   offset [1:3];         // RSI1/2/3 veri adres offset'i
        bit [31:0]   huzme_id;
        int unsigned m;                    // SIFPGA alma huzme sayisi
        int unsigned darbe;                // toplam darbe sayisi
        int unsigned ornek;                // darbedeki ornek sayisi
        int unsigned nsample;              // N = darbe * ornek (huzme basina ornek sayisi)
        bit [7:0]    shob_use;             // bit0 SHOB-1, bit1 SHOB-2
        bit [7:0]    mode;                 // 0: HO (SHO), 1: Bypass
        int unsigned n_k [1:3];            // RSI basina indirilecek huzme ("kanal") sayisi
        longint      t_ns;
        function new();
            for (int k = 1; k <= 3; k++) begin offset[k] = 0; n_k[k] = 0; end
            huzme_id = 0; m = 0; darbe = 0; ornek = 0; nsample = 0; shob_use = 0; mode = 0; t_ns = 0;
        endfunction
    endclass

    huzme_tur    turlar[$];                // senaryodan gelen turlar (sirayla)
    int unsigned rsi_tur_idx [1:3] = '{0, 0, 0};   // her RSI'nin kapattigi tur sayisi

    // Surucunun (scn_pkg::driver) her TLP icin cagirdigi izleyici. cont=1 ise bolunmus mesajin devam paketidir.
    function automatic void track_cfg_msgs(bit [7:0] pkt[], bit cont);
        bit [63:0] id;
        huzme_tur  t;
        if (cont || pkt.size() < 24) return;
        id = bytes_to_val(pkt, 16, 4, 1'b0);
        if (id[31:0] == ID_ADRES_ATAMA && pkt.size() >= 24 + 120) begin
            for (int k = 1; k <= NRSI; k++)
                rsi_start_addr[k] = bytes_to_val(pkt, 24 + 96 + 8 * (k - 1), 8, 1'b0);
            rsi_start_valid = 1'b1;
            $display("[RSI] adres atama: RSI1=%h RSI2=%h RSI3=%h", rsi_start_addr[1], rsi_start_addr[2], rsi_start_addr[3]);
        end else if (id[31:0] == ID_SIFPGA_HUZPAR && pkt.size() >= 24 + 39) begin
            t = new();
            for (int k = 1; k <= NRSI; k++) t.offset[k] = bytes_to_val(pkt, 24 + 8 * (k - 1), 8, 1'b0);
            t.huzme_id = bytes_to_val(pkt, 24 + 24, 4, 1'b0);
            t.m        = bytes_to_val(pkt, 24 + 28, 2, 1'b0);
            t.darbe    = bytes_to_val(pkt, 24 + 30, 2, 1'b0);
            t.ornek    = bytes_to_val(pkt, 24 + 32, 2, 1'b0);
            t.nsample  = t.darbe * t.ornek;
            t.shob_use = pkt[24 + 34];
            t.mode     = pkt[24 + 35];
            for (int k = 1; k <= NRSI; k++) t.n_k[k] = pkt[24 + 35 + k];
            t.t_ns     = $time;
            turlar.push_back(t);
            $display("[RSI] tur #%0d (1DEA0003): huzme_id=%h M=%0d darbe=%0d ornek=%0d N=%0d n_k=%0d/%0d/%0d offset=%h/%h/%h",
                     turlar.size(), t.huzme_id, t.m, t.darbe, t.ornek, t.nsample, t.n_k[1], t.n_k[2], t.n_k[3],
                     t.offset[1], t.offset[2], t.offset[3]);
        end
    endfunction

    // ---- tur ozeti: her RSI kendi turunu raporlar; hepsi raporlayinca birlesim kontrolu yapilir ----
    class tur_rapor;
        bit          reported [1:3];
        bit          basarili [1:3];       // MSI1 ile mi kapandi
        bit          dogru    [1:3];       // RSI'nin kendi kontrolleri gecti mi
        int unsigned nbeam    [1:3];
        string       rule     [1:3];
        int unsigned beam_cnt [int unsigned];   // huzme sirasi -> kac RSI'de goruldu
        bit          printed;
        function new();
            for (int k = 1; k <= 3; k++) begin reported[k] = 0; basarili[k] = 0; dogru[k] = 0; nbeam[k] = 0; rule[k] = ""; end
            printed = 0;
        endfunction
    endclass

    tur_rapor raporlar[$];
    int       rsi_sum_fd = 0;

    function automatic void rsi_sum_log(string s);
        if (rsi_sum_fd == 0) begin
            rsi_sum_fd = $fopen("rsi_tur_ozeti.txt", "w");
            if (rsi_sum_fd != 0) begin
                $fdisplay(rsi_sum_fd, "# RSI tur ozeti (v1.0.7): her satir bir huzme turu; RSI modelleri raporlayinca yazilir");
            end
        end
        if (rsi_sum_fd != 0) begin
            $fdisplay(rsi_sum_fd, "%s", s);
            $fflush(rsi_sum_fd);
        end
    endfunction

    // RSI 'rsi' kendi 'tur' (0 tabanli) turunu raporlar. beams: bu RSI'de gorulen huzme sirasi listesi.
    function automatic void rsi_report_round(int rsi, int tur, bit basarili, bit dogru, string rule,
                                             int unsigned beams[$]);
        tur_rapor    r;
        huzme_tur    t;
        bit          all_in;
        bit          all_ok;
        int unsigned expected_beams;
        int unsigned missing, dup;
        string       line;
        while (raporlar.size() <= tur) begin
            r = new();
            raporlar.push_back(r);
        end
        r = raporlar[tur];
        r.reported[rsi] = 1'b1;
        r.basarili[rsi] = basarili;
        r.dogru[rsi]    = dogru;
        r.rule[rsi]     = rule;
        r.nbeam[rsi]    = beams.size();
        foreach (beams[i]) begin
            if (r.beam_cnt.exists(beams[i])) r.beam_cnt[beams[i]]++;
            else                              r.beam_cnt[beams[i]] = 1;
        end
        t = (tur < turlar.size()) ? turlar[tur] : null;
        // hangi RSI'lerin raporlamasi bekleniyor: n_k > 0 olanlar (yapilandirma yoksa raporlayanlar)
        all_in = 1'b1;
        for (int k = 1; k <= NRSI; k++)
            if (t != null && t.n_k[k] > 0 && !r.reported[k]) all_in = 1'b0;
        if (t == null) all_in = (r.reported[1] || r.reported[2] || r.reported[3]);
        if (!all_in || r.printed) return;
        r.printed = 1'b1;

        all_ok = 1'b1;
        line = $sformatf("TUR %0d", tur + 1);
        if (t != null) line = {line, $sformatf(" huzme_id=%h M=%0d N=%0d", t.huzme_id, t.m, t.nsample)};
        for (int k = 1; k <= NRSI; k++)
            if (r.reported[k]) begin
                line = {line, $sformatf(" | RSI%0d: %0s huzme=%0d %0s", k, r.basarili[k] ? "YAZILDI" : "YAZILAMADI",
                                        r.nbeam[k], r.dogru[k] ? "DOGRU" : "YANLIS")};
                if (!r.basarili[k] || !r.dogru[k]) all_ok = 1'b0;
            end
        rsi_sum_log(line);
        if (all_ok && t != null) begin
            // birlesim: 0..M-1 her huzme tam bir kez, RSI'ler arasinda
            expected_beams = t.m;
            missing = 0; dup = 0;
            for (int unsigned b = 0; b < expected_beams; b++) begin
                if (!r.beam_cnt.exists(b)) missing++;
                else if (r.beam_cnt[b] > 1) dup++;
            end
            rsi_sum_log($sformatf("  birlesim: %0d huzme bekleniyor, eksik=%0d, birden cok RSI'de=%0d, birlesim kurali: RSI1=%0s RSI2=%0s RSI3=%0s -> %0s",
                                  expected_beams, missing, dup, r.rule[1], r.rule[2], r.rule[3],
                                  (missing == 0 && dup == 0) ? "DOGRU" : "YANLIS"));
        end else if (!all_ok) begin
            rsi_sum_log("  tur sonucu: BASARISIZ ya da YANLIS (ayrintilar rsiN_out.txt dosyalarinda)");
        end
    endfunction

endpackage
