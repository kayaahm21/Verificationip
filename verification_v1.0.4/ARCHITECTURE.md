# Mimari - PCIe VIP v1.0.3

Bu doküman VIP'in **ne yaptığını, nasıl çalıştığını ve kodun nasıl organize olduğunu** anlatır.
Hızlı kullanım için [README.md](README.md)'ye bakın.

---

## 1. Amaç ve kapsam

Gerçek sistemde bir **UltraScale+ PCIe IP**'si, FPGA ile işlemci (CPU) arasındaki PCIe trafiğini taşır.
Simülasyonda gerçek bir PCIe bağlantısı olmadığı için bu IP'nin yerine `sim_model_cpu` adlı bir **VIP** konur.
VIP iki yönde de çalışır:

| Yön | Port | Ne olur |
|---|---|---|
| **CPU → FPGA** | `m_axis_cq_*` (Completer Request) | Senaryo dosyasındaki mesajlar TLP olarak tasarıma sürülür |
| **FPGA → CPU** | `s_axis_rq_*` (Requester Request) + MSI | FPGA, işlemcinin hafızasındaki circular buffer'a yazar; kesme gelince işlemci buffer'ı okur |

Ek olarak VIP: `user_clk` (125 MHz), `user_reset` (aktif yüksek), dahili link-up, MSI cevabı (`msi_sent`) ve
huzme başı (HB) yönetimini yapar.

**Kapsam dışı:** gerçek IP'nin tüm `cfg_*` portları, RC/CC kanalları, PCIe fiziksel katmanı, FPGA'nın memory
**read** istekleri ve completion üretimi, SHOB/IUB gibi ek buffer'lar (yalnız SIFPGA buffer'ı var).

---

## 2. Genel görünüm

```
                           senaryo dosyası (input_data.txt)
                                      │ satır satır
                                      ▼
                            ┌───────────────────┐
                            │     generator     │ (parser)  satır -> scn_cmd
                            └─────────┬─────────┘
                                      │ mailbox #(scn_cmd)
                                      ▼
   ┌───────────────────────────────────────────────────────────────────────────┐
   │                                 driver                                    │
   │  CMD_TLP        ─▶ (1DEA0001 ise cpu.maybe_program) ─▶ drive_item() ─▶ CQ  │──▶ m_axis_cq_*  ──▶ FPGA
   │  CMD_WAIT_NS    ─▶ #ns                                                    │
   │  CMD_WAIT_BEAM  ─▶ beam_ctrl.wait_beam()  ◀── huzme_basi_obs              │
   │  CMD_PLAN_BEAM  ─▶ beam_ctrl.plan(ns)     ──▶ huzme_basi_gen              │
   └───────────────────────────────────────────────────────────────────────────┘

   FPGA ──▶ s_axis_rq_* ──▶ rq_assembler ──▶ rq_pkt ──▶ cpu_model.on_pkt ──▶ cpu_mem (hafıza)
                                                              │
   FPGA ──▶ cfg_interrupt_msi_int ──▶ msi_sent ──▶ ISR ──▶ cpu_model.run_isr
                                                              │ buffer'dan mesajları ayrıştır
                                                              ▼
                                                          cpu_out.txt   (+ rq_trace.txt)
```

---

## 3. Dosyalar

| Dosya | Tür | İçerik |
|---|---|---|
| `src/axis_tx_if.sv` | interface | CQ AXI-S arayüzü (`tvalid/tready/tdata/tkeep/tlast/tuser`) |
| `src/beam_if.sv` | interface | HB için `obs` (gözlenen), `gen` (üretilen), `clk` |
| `src/cpu_pkg.sv` | package | **(v1.0.3)** `rq_pkt`, `rq_assembler`, `cpu_mem`, `cpu_buffer`, `cpu_model` |
| `src/scn_pkg.sv` | package | `scn_cmd`, `tlp_item`, `generator`, `beam_ctrl`, `driver` |
| `src/sim_model_cpu.sv` | module | IP yerine geçen VIP; VHDL'den instantiate edilir |
| `tb/tb_cpu_check.sv` | testbench | **(v1.0.3)** FPGA→CPU yönü self-check testi |
| `tb/tb_cq_check.sv` | testbench | **(v1.0.3)** CPU→FPGA yönü self-check testi |
| `tb/tb_system_top.vhd` / `.sv` | testbench | Tüm sistemi (Top) içeren üst seviye TB |
| `tb/tb_top.sv` | testbench | Sadece `design_1_wrapper` için bağımsız TB |
| `docs/sim_model_cpu_inst.vhd` | örnek | PcieTop.vhd için instantiation |
| `examples/scenario_example.txt` | örnek | Her komuttan örnek |
| `examples/scenario_v103.txt` | örnek | Buffer'ı programlayan `1DEA0001` mesajı |
| `examples/scenario_cq_test.txt` | örnek | `tb_cq_check` senaryosu |
| `tb/tb_fill_check.sv` | testbench | **(v1.0.3)** buffer doldurma / sarma / taşma testi |
| `examples/buffer_fill_small.txt`, `buffer_fill_4k.txt`, `scenario_fill_cfg.txt` | örnek | Buffer doldurma senaryoları |
| `tools/gen_buffer_fill.py` | betik | Buffer doldurma senaryosu üretici |
| `test/run_verilator.sh`, `test/flatten_for_verilator.py` | betik | Verilator test koşucusu |

**Derleme sırası:** `axis_tx_if.sv` → `beam_if.sv` → `cpu_pkg.sv` → `scn_pkg.sv` → `sim_model_cpu.sv`.
(`scn_pkg`, `cpu_pkg`'den `cpu_model`'i import eder.)

---

## 4. CPU → FPGA yönü (senaryo)

Bu bölüm v1.0.2 ile aynıdır; özet:

### 4.1 Senaryo dosyası
Her satır bir komut; `#` ve `//` yorum. **İlk alan komutu belirler:**

| İlk alan (hex) | Komut | Devamı |
|---|---|---|
| `99999999` | HB bekle (`CMD_WAIT_BEAM`) | yok |
| `88888888` | süre bekle (`CMD_WAIT_NS`) | `<ns>` |
| `77777777` | HB planla (`CMD_PLAN_BEAM`) | `<ns>` |
| başka | TLP (`CMD_TLP`), ilk alan **adres** | `MSGID` (hex), `LEN` (onluk), `LEN` kadar bayt (hex) |

Bu üç özel değer gerçek TLP adresi olarak **kullanılamaz**. Hatalı satırlar atlanır, satır numarasıyla `$error` basılır.

### 4.2 Yürütme
`driver.run()` komutları **sırayla** çalıştırır: TLP tamamen sürülmeden, `88888888` süresi dolmadan veya `99999999` HB
gelmeden sıradaki komuta geçilmez. Tek istisna `77777777`: bloklamaz, sayaç arka planda çalışır. Bu yüzden her
`99999999`'dan **önce** ona karşılık gelen bir `77777777` bulunmalıdır.

### 4.3 TLP yapısı
| Bayt | Alan |
|---|---|
| 0-15 | **CQ descriptor** (DW0-1 adres, DW2: DWORD sayısı + tip `0001` MemWr, DW3 şimdilik 0) |
| 16-19 | `msg_id` (little-endian) |
| 20-23 | `len` = yalnız veri baytı sayısı (little-endian) |
| 24… | veri |

256-bit AXI-S'te 32 bayt/beat; `tkeep` DWORD başına (8 bit); `tuser` UltraScale+ CQ düzeni
(`first_be[3:0]`, `last_be[7:4]`, `byte_en[39:8]` = yalnız payload baytları, `sop[40]` ilk beat'te).
`tready` 0 iken aynı beat tutulur (backpressure).

### 4.4 Huzme başı
İki port: `huzme_basi_obs` (giriş, `99999999` bunu izler) ve `huzme_basi_gen` (çıkış, `77777777` bunu sürer).
`BEAM_SOURCE="SCRIPT"` iken VHDL'de `HuzmeBasi <= huzme_basi_gen_sig;` ile ikisi birleştirilir; gerçek modül
bağlanınca bu atama silinir ve `BEAM_SOURCE="DESIGN"` seçilir. Ayrıntı: `docs/sim_model_cpu_inst.vhd`.

---

## 5. FPGA → CPU yönü (v1.0.3)

### 5.1 Olay akışı
FPGA bir mesaj yazarken **iki ayrı memory write TLP'si** gönderir, sonra kesme verir:

```
1) veri TLP'si     : mesaj, buffer içine yazılır         (adres = buffer içindeki yazma konumu)
2) pointer TLP'si  : "en son yazılan yer" pointer adresine yazılır   (4 veya 8 bayt)
3) MSI             : kesme
```
İki geçerli dizilim:

```
A) veri1 -> pointer1 -> kesme                           (kesme başına 1 mesaj)
B) veri1 -> pointer1 -> veri2 -> pointer2 -> kesme      (birleşmiş kesme: 2 mesaj, tek kesme)
```
İşlemci tarafı ikisini de aynı kodla çözer (bkz. 5.6).

### 5.2 Buffer'ın programlanması (`1DEA0001`)
CPU→FPGA yönünde giden `1DEA0001` mesajının **verisi**, buffer'ı tanımlar (hepsi **little-endian**, 8'er bayt):

| Veri baytı | Anlam |
|---|---|
| `[0..7]` | circular buffer başlangıç adresi |
| `[8..15]` | circular buffer boyutu (bayt) |
| `[16..23]` | yazma pointer'ının tutulduğu bellek adresi |
| `[24..]` | SHOB/IUB vb. - şimdilik **yok sayılır** |

`driver`, bir CMD_TLP'yi sürmeden **önce** `cpu.maybe_program()`'ı çağırır. ID `CFG_MSG_ID`'ye eşitse işlemci
modeli buffer'ı kurar (`base`, `size`, `ptr_addr`, `last_ptr = base`) ve pointer bölgesine başlangıç değerini (= `base`)
yazar. Aynı mesaj tekrar gelirse buffer yeniden programlanır. Böylece senaryo ile işlemci modeli hiç ayrışmaz;
FPGA'nın ilk yazısı geldiğinde model zaten hazırdır.

### 5.3 `rq_assembler` ve `rq_pkt`: TLP'yi yakalama
`sim_model_cpu` her clock'ta `tvalid && tready` ise beat'i `rq_assembler.push_beat()`'e verir:

- İlk beat'te `tuser[3:0]` (`first_be`) ve `tuser[7:4]` (`last_be`) alınır.
- Her beat'te `tkeep` (DWORD başına bit) geçerli DWORD'ları belirler; baytlar sıraya eklenir.
- `tlast`'ta 16 baytlık descriptor çözülür (UltraScale+ RQ, little-endian):
  `DW0[31:2]` ve `DW1` = adres, `DW2[10:0]` = DWORD sayısı, `DW2[14:11]` = tip (`0001` MemWr).
- Payload, descriptor'ın hemen arkasından başlar (DWORD hizalı mod). Sonuç bir `rq_pkt`'tir.

> `tuser` bit konumları (RQ `first_be/last_be`) ve DWORD hizalı payload varsayımı PG213'ten doğrulanmalıdır.

### 5.4 `cpu_mem`: işlemci hafızası
Seyrek (sparse) **bayt adreslenebilir** hafıza (`bit [7:0] mem[bit [63:0]]`). Boyut belirlemek gerekmez; sadece
yazılan adresler yer kaplar. `read_byte` / `read_field(adres, n, big_endian)` / `read32` ile 32 bit satır yüklemesi
yapılır. Yazılmamış adres okunursa 0 döner ve sayaç artar.

### 5.5 `cpu_model.on_pkt`: gelen TLP'yi hafızaya yazma
- Sadece **MemWr** kabul edilir. FPGA'nın MemRd göndermesi beklenmez; gelirse uyarı verilip atılır.
- Byte enable: ilk DWORD `first_be`, son DWORD `last_be`, aradakiler tam. Sadece etkin baytlar yazılır.
- **Buffer sonunu aşan yazma:** FPGA yazmayı buffer sonunda iki TLP'ye bölüyorsa her biri kendi adresine yazılır
  (normal durum). Tek TLP buffer içinden başlayıp sonunu aşıyorsa VIP taşan baytları **buffer başına sarar** ve
  `wrap_events` sayacını artırıp uyarı basar (veri kaybolmaz, ama olay görünür).
- Buffer dışına (ve pointer bölgesi dışına) yazma uyarı verir ama yine de hafızaya yazılır.
- Pointer bölgesine (`ptr_addr`) yazılırsa pointer genişliği (4 veya 8 bayt) yazımın DWORD sayısından öğrenilir.

### 5.6 ISR (`cpu_model.run_isr`): kesme servis rutini
Tetikleme (`sim_model_cpu` içinde):

1. FPGA `cfg_interrupt_msi_int`'i yükseltir. VIP her yükselen kenar için 3 clock sonra **tek clock'luk**
   `cfg_interrupt_msi_sent` darbesi verir (tasarım `msi_int`'i `sent`'e kadar tutsa da, tek clock'luk darbe
   verse de çalışır).
2. `msi_sent` gelince ISR: o ana kadar gelen tüm RQ TLP'lerinin işlenmesini bekler (MSI yazmaların ardından
   gelir), `ISR_LATENCY_NS` bekler, `run_isr()` çalışır. Kesme bayrağı (`irq_flag`) tutulur, kaçan kesme olmaz.

`run_isr()`:

1. `yeni_ptr` = pointer adresindeki değer (`ptr_width` bayt, little-endian). `base+size` ise `base`'e normalleşir.
2. `yeni_ptr` buffer dışındaysa hata; `yeni_ptr == last_ptr` ise **sahte kesme** (çıktı yok).
3. `avail = (yeni_ptr - last_ptr) mod size`.
4. `avail` bitene kadar **mesaj mesaj** ayrıştırılır: 4 bayt ID + 4 bayt `len` + `len` bayt veri
   (`len` = yalnız veri). Okumalar buffer sonunu aşınca başa sarar (`ring_addr`).
5. Her mesaj `cpu_out.txt`'ye `MSGID LEN BYTE0 BYTE1 ...` olarak yazılır.
6. `last_ptr` = bitiş konumu.

**Neden birleşmiş kesme sorun değil:** ISR "kaç kesme geldi" diye saymaz; `last_ptr` ile güncel pointer arasındaki
**her şeyi** `len` alanlarına göre mesajlara böler. B dizilimi (iki mesaj, tek kesme) bu yüzden 2 çıktı satırı üretir.

**Pointer "yazma tamamlandı" işaretidir:** veri2 yazılmış ama pointer2 henüz gelmemişse ISR yalnızca pointer'ın
gösterdiği yere kadar okur; yarım mesaj görmez. Veri bir sonraki kesmede okunur. Kaçan bir kesme veriyi kaybettirmez.

### 5.7 Buffer taşması (overrun) tespiti
Model, buffer'a yazılan fakat ISR'nin henüz okumadığı baytları sayar (`unread_bytes`). FPGA okunmamış verinin
üstüne yazarsa (okunmamış bayt > buffer boyutu) `BUFFER TASTI` uyarısı verilir, `overrun_count` artar ve iz dosyasına
`!! BUFFER TASTI` satırı yazılır. İşlemci FPGA'ya okuma pointer'ı bildirmediği için gerçek sistemde de bu durum
yalnızca yazılımın yeterince hızlı okumasıyla önlenir; model bu durumu görünür kılar. Taşmadan sonra pointer
farkı belirsiz olduğundan ISR hatalı mesaj ayrıştırabilir; uyarı bu yüzden önemlidir.

### 5.8 Çıktı dosyaları
- **`cpu_out.txt`** - her satır bir mesaj, girdi dosyasıyla aynı mantıkta:
  `1DEA0005 0` veya `000000A1 12 A1 A2 A3 ...` (ID 8 haneli hex, LEN onluk, bayt hex).
- **`rq_trace.txt`** - zaman damgalı iz: programlama (`CFG`), her gelen TLP (tip, adres, DWORD sayısı, byte enable),
  pointer güncellemeleri, buffer sonu aşımı, her ISR'nin sonucu.

---

## 6. `sim_model_cpu` modülü

### 6.1 Portlar
| Port | Yön | Açıklama |
|---|---|---|
| `sys_clk` | in | Dışarıdan gelir; VIP içinde kullanılmıyor |
| `user_clk` | out | 125 MHz |
| `user_reset` | out | Aktif yüksek; başlangıçta 20 clock reset |
| `m_axis_cq_tdata[255:0]`, `tkeep[7:0]`, `tlast`, `tuser[87:0]`, `tvalid` | out | CQ: VIP → tasarım |
| `m_axis_cq_tready` | in | Tasarımdan |
| `s_axis_rq_tdata[255:0]`, `tkeep[7:0]`, `tlast`, `tuser[61:0]`, `tvalid` | in | RQ: tasarım → VIP |
| `s_axis_rq_tready[3:0]` | out | Her zaman `4'hF` |
| `cfg_interrupt_msi_int[31:0]` | in | MSI isteği |
| `cfg_interrupt_msi_sent` | out | Her istek için 3 clock sonra tek clock'luk darbe |
| `cfg_interrupt_msi_fail` | out | 0'a sabit |
| `huzme_basi_obs` | in | Tasarımdaki HB teli (izlenir) |
| `huzme_basi_gen` | out | VIP'in ürettiği HB |

Port adları **küçük harflidir** (VHDL çağrısında harf duyarlılığı sorunu çıkmasın diye).

### 6.2 Parametreler
`INPUT_FILE`, `BEAM_SOURCE`, `BEAM_PULSE_CLKS`, `BEAM_ACTIVE_HIGH`, `OUT_FILE`, `TRACE_FILE`, `ISR_LATENCY_NS`,
`CFG_MSG_ID`, `CFG_BIG_ENDIAN`, `PTR_BIG_ENDIAN`, `MSG_BIG_ENDIAN`, `CQ_KEEP_WIDTH`, `RQ_KEEP_WIDTH`
(varsayılanlar README.md'de). `+TLP_FILE=`, `+BEAM_SOURCE=`, `+CPU_OUT=`, `+RQ_TRACE=` komut satırı argümanları
parametrelerin yerine geçer.

### 6.3 Başlangıç sekansı
```
t = 0         user_reset = 1, link_up = 0
+20 clock     user_reset = 0
+20 clock     link_up = 1  -> driver.reset() döner
sonra         driver.run() arka planda başlar, generator.run() dosyayı okur
```
İşlemci modeli (`cpu_model`) ve RQ birleştirici t=0'da kurulur; `driver` buffer'ı programlamak için ona ihtiyaç duyar.

---

## 7. VHDL ile entegrasyon

Ayrıntılı örnek: `docs/sim_model_cpu_inst.vhd`. v1.0.2'ye göre **port değişikliği yoktur**.

1. Dosyaları **simulation source** olarak, tip `SystemVerilog`, kütüphane `xil_defaultlib` ile ekle.
2. SV portlarına yalnızca `std_logic` / `std_logic_vector` bağlanabilir; özel dizi tipleri veya record alanları için
   VHDL'de standart tipli ara sinyal kullanın.
3. `HuzmeBasi` `PcieTop`'un giriş portuysa HB'yi `Top` seviyesinde sürün (`HuzmeBasiVip` çıkışıyla).
4. Gerçek IP dalı (`SIM_MODE = FALSE`) ile VIP dalı birbirini dışlamalıdır.

---

## 8. Test

```bash
./test/run_verilator.sh      # Verilator >= 5.0, python3
```

| Test | Doğruladığı |
|---|---|
| `tb_cpu_check` (FPGA→CPU) | T1 tek mesaj; T2 **birleşmiş kesme** (2 mesaj/1 kesme); T3 buffer sonunda FPGA'nın böldüğü yazma; T4 buffer sonunu aşan tek TLP (sarma); T5 sahte kesme; T6 pointer gelmeden kesme (okunmaz), sonra okunur; T7 `len=0`; T8 8 baytlık pointer; T9 `pointer = base+size` normalleşmesi. Çıktı dosyası 11 satır, beklenenle birebir; sayaçlar kontrol edilir |
| `tb_cq_check` (CPU→FPGA) | TLP baytları (descriptor/ID/len/payload) bağımsız oluşturulan beklenenle aynı; 1, 4 ve 1 beat'lik TLP'ler; `tready` her 3 clock'ta 1 kez 0 iken veri bozulmuyor; `sop` yalnız ilk beat'te; HB zamanı ~1324 ns; `88888888 400` aralığı 400..440 ns |

| `tb_fill_check` (doldurma) | 256 baytlık buffer'da 49 mesaj: ack(8) + 2 tur = **tam 256 B (buffer sonunda tam bitiş)**; tur 1-6 FPGA yazmayı sonda iki TLP'ye böler, tur 7-12 32 baytlık TLP buffer sonunu aşar (VIP basa sarar); mesajlar 32 baytlık TLP'lere bölünür; 3'lü gruplar için 3 kesme (24 sahte); son olarak 12 × 24 bayt kesmesiz yazım → `BUFFER TASTI` tam 1 kez. Çıktı dosyası 49 satır, beklenenle birebir; hata sayacı 0 |

Kod kasıtlı bozularak (mutasyon: ayrıştırmada yanlış ilerleme, `base+size` normalleştirmesi kaldırma,
`first_be` maskesini kapatma) testlerin hatayı **yakaladığı** doğrulanmıştır.

### Simülatörler arası farklar (öğrenilenler)
- Verilator parametreli `virtual interface`'i desteklemez; test betiği kopyada interface'i parametresizleştirir
  (`flatten_for_verilator.py`). Repodaki kaynaklar Vivado/xsim için olduğu gibi kalır.
- Verilator `if (f(...))` içindeki çıkış argümanlı fonksiyon çağrısını iki kez yürütebilir; bu yüzden
  `sim_model_cpu` içinde çağrı ayrı bir ifadeye alındı (`rx_done = asm.push_beat(...); if (rx_done) ...`).
- `cross` SystemVerilog'da ayrılmış sözcüktür (değişken adı olarak kullanılamaz).
- Verilator, `automatic` görevlerdeki yerel kuyrukları çağrılar arasında temizlemeyebilir. Testbench görevlerinde bu
  yüzden her kuyruk çağrının başında `.delete()` ile açıkça temizlenir.

### Doğrulanmayanlar
Vivado/xsim derlemesi, VHDL karma dil entegrasyonu, `tb_system_top` ve `tb_top` (`design_1_wrapper` gerektirir).

---

## 9. Yeni komut / yeni buffer eklemek

**Yeni senaryo komutu:** `scn_pkg.sv`'de yeni `ADDR_...` sabiti ve `cmd_kind_e` değeri; `generator.parse_line()`
içindeki `case`'e dal; `driver.run()` içindeki `case`'e yürütme.

**İkinci buffer (SHOB/IUB vb.):** `cpu_model` bugün tek `cpu_buffer` tutar. Genişletmek için `buffer`'ı bir liste
yapın, `program_from_tlp()`'de `[24..]` sonrasındaki alanları aynı 3×8 bayt düzeniyle ayrıştırın, `on_pkt`'te yazılan
adresin hangi buffer'a ait olduğunu bulun ve `run_isr()`'yi her buffer için çalıştırın. MSI vektörünün hangi buffer'ı
gösterdiği bilgisi gerekir.

---

## 10. Varsayımlar ve bilinen sınırlar

Varsayımlar (yanlışsa `rq_trace.txt`'ten hemen görülür; çoğu parametre ile değiştirilebilir):

- Bayt sırası: tüm çok baytlı alanlar **little-endian** (`*_BIG_ENDIAN` parametreleri).
- **Pointer değeri** = buffer içindeki **mutlak adres**, "bir sonraki boş bayt"; 4 veya 8 bayt. Başlangıçta = buffer başı.
- FPGA'nın yazdığı mesajda `len` = yalnız **veri baytı sayısı**. Mesajlar buffer'da **boşluksuz** art arda.
- FPGA ilk mesajı buffer başına yazar.
- Buffer hiçbir zaman tamamen dolmaz (`yeni_ptr == last_ptr` hem "boş" hem "tam dolu" anlamına gelebilir).
- Her `1DEA0001` mesajı buffer'ı yeniden programlar (`last_ptr = base`).

Sınırlar:

- Tek buffer (SIFPGA). Mesajın ilk 24 baytından sonrası yok sayılır.
- FPGA'nın MemRd istekleri ve completion yolu yok.
- CQ descriptor'ında requester ID / tag / BAR / TC / attr alanları 0; büyük yazmalar MPS/4KB sınırında bölünmez.
- `99999999` için zaman aşımı yok; HB gelmezse senaryo orada bekler.
- Üç özel adres değeri (`99999999`, `88888888`, `77777777`) gerçek TLP adresi olarak kullanılamaz.
- PG213 ile doğrulanması gerekenler: RQ/CQ `tuser` bit konumları, `byte_en` ve parity düzeni.
- Dosyaya yazma anlık (`$fflush`): hem `cpu_out.txt` hem `rq_trace.txt` her yazımdan sonra diske boşaltılır; simülasyon açıkken (`run 2 us` gibi) de okunabilir.
