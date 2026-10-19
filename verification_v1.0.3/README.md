# PCIe VIP - v1.0.3 (senaryo + islemci modeli)

Radar sistemi doğrulaması için, gerçek **Xilinx UltraScale+ PCIe IP**'sinin yerine konan
SystemVerilog VIP. İki yönü de kapsar:

| Yön | Ne yapar | Sürüm |
|---|---|---|
| **CPU → FPGA** (`m_axis_cq`) | Senaryo dosyasındaki TLP'leri sürer; huzme başı (HB) bekler / üretir; süre bekler | v1.0.2 |
| **FPGA → CPU** (`s_axis_rq`, MSI) | FPGA'nın işlemci hafızasına yazdığı TLP'leri alır, **circular buffer**'a yazar, **kesme gelince** buffer'dan mesajları okuyup `cpu_out.txt`'ye yazar | **v1.0.3 (yeni)** |

Ayrıntılı mimari: **[ARCHITECTURE.md](ARCHITECTURE.md)**

## Hızlı başlangıç

1. Dosyaları Vivado'ya **simulation source** olarak ekle (tip: SystemVerilog, kütüphane: `xil_defaultlib`).
   Derleme sırası:
   ```
   src/axis_tx_if.sv -> src/beam_if.sv -> src/cpu_pkg.sv -> src/scn_pkg.sv -> src/sim_model_cpu.sv
   ```
2. `PcieTop.vhd`'deki VIP instantiation'ı `docs/sim_model_cpu_inst.vhd` ile değiştir
   (v1.0.2'den **port değişikliği yok**; sadece yeni isteğe bağlı generic'ler var).
3. Senaryo dosyasını simülasyon çalışma dizinine `input_data.txt` adıyla koy (ya da `+TLP_FILE=<yol>`).
   Senaryoda buffer'ı programlayan `1DEA0001` mesajı bulunmalı (örnek: `examples/scenario_v103.txt`).
4. Simülasyon sonunda çalışma dizininde:
   - `cpu_out.txt`: işlemcinin ayrıştırdığı mesajlar (`MSGID LEN BYTE0 BYTE1 ...`)
   - `rq_trace.txt`: gelen tüm TLP'ler, pointer güncellemeleri, ISR'ler (zaman damgalı)

## Senaryo dosyası (özet)

| Satır | Anlamı |
|---|---|
| `ADRES MSGID LEN BYTE0 BYTE1 ...` | TLP gönder (ADRES, MSGID hex; LEN onluk bayt sayısı, 4'ün katı) |
| `99999999` | Huzme başını bekle |
| `88888888 <ns>` | `<ns>` nanosaniye bekle |
| `77777777 <ns>` | `<ns>` sonra huzme başı üret (beklemez, arka planda) |
| `# ...` / `// ...` | Yorum |

Her `99999999`'dan **önce** onu üretecek bir `77777777` olmalı (SCRIPT modunda), aksi halde senaryo orada kilitlenir.

## Buffer'ın programlanması (`1DEA0001`)

CPU→FPGA yönünde giden `1DEA0001` mesajının **verisinin ilk 24 baytı** (hepsi little-endian):

| Veri baytları | Anlamı |
|---|---|
| `[0..7]` | circular buffer başlangıç adresi |
| `[8..15]` | circular buffer boyutu (bayt) |
| `[16..23]` | yazma pointer'ının tutulduğu bellek adresi |
| `[24..]` | şimdilik yok sayılır (SHOB/IUB vb.) |

VIP bu mesajı sürerken içeriğini dinleyip işlemci tarafındaki buffer'ı da kurar.

## Önemli parametreler (`sim_model_cpu`)

| Parametre | Varsayılan | Anlamı |
|---|---|---|
| `INPUT_FILE` | `"input_data.txt"` | Senaryo dosyası (`+TLP_FILE=` ile ezilir) |
| `BEAM_SOURCE` | `"SCRIPT"` | `"SCRIPT"`: HB'yi VIP üretir. `"DESIGN"`: gerçek modül üretir (`+BEAM_SOURCE=`) |
| `BEAM_PULSE_CLKS` / `BEAM_ACTIVE_HIGH` | `1` / `1` | Üretilen HB darbesi genişliği / polarite |
| `OUT_FILE` / `TRACE_FILE` | `cpu_out.txt` / `rq_trace.txt` | Çıktı dosyaları (`+CPU_OUT=`, `+RQ_TRACE=`) |
| `ISR_LATENCY_NS` | `100` | MSI'dan sonra ISR'nin başlaması için bekleme |
| `CFG_MSG_ID` | `32'h1DEA0001` | Buffer'ı programlayan mesajın ID'si |
| `CFG_BIG_ENDIAN` / `PTR_BIG_ENDIAN` / `MSG_BIG_ENDIAN` | `0` / `0` / `0` | Bayt sırası: 0 = little-endian |
| `CQ_KEEP_WIDTH` / `RQ_KEEP_WIDTH` | `8` / `8` | `tkeep` genişlikleri |

## Test

```bash
./test/run_verilator.sh      # Verilator >= 5.0 gerekir
```
İki kendi kendini kontrol eden test koşar (**şu an hepsi geçiyor**):

| Test | Neyi doğrular |
|---|---|
| `tb/tb_cpu_check.sv` | FPGA→CPU: 11 mesaj; tek kesme/tek mesaj, **birleşmiş kesme (2 mesaj/1 kesme)**, buffer sonuna denk gelen bölünmüş yazma, buffer sonunu aşan tek TLP, sahte kesme, pointer gelmeden kesme, `len=0`, 8 baytlık pointer, pointer = base+size |
| `tb/tb_cq_check.sv` | CPU→FPGA: TLP baytları (descriptor/ID/len/payload), çok beat'li TLP, `tkeep`/`tuser`, `tready` ile bekletme, `77777777`/`99999999`/`88888888` zamanlaması |

Testlerin gerçekten hata yakaladığı, kodu kasıtlı bozarak (mutasyon) doğrulandı.

## Test durumu (dürüst not)

- Doğrulandı: Verilator 5.020 üzerinde, `sim_model_cpu` modülü dahil iki test de geçiyor.
- **Doğrulanmadı:** Vivado/xsim derlemesi, VHDL ile karma dil entegrasyonu, `tb_system_top` ve `tb_top`
  (`design_1_wrapper` gerektirir). İlk Vivado derlemesinde küçük hatalar çıkabilir.
- Varsayımlar (ARCHITECTURE.md bölüm 10): pointer değeri = buffer içi mutlak adres (bir sonraki boş bayt);
  FPGA mesajındaki `len` sadece veri baytı; mesajlar buffer'da boşluksuz.

## Sürümler
- `verification_v1.0.2/`: CPU→FPGA, senaryo + HB.
- `verification_v1.0.3/` (bu klasör): v1.0.2 + FPGA→CPU islemci modeli.
