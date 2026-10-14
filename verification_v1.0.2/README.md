# PCIe CQ VIP - v1.0.2 (senaryo tabanlı)

Radar sistemi doğrulaması için, gerçek **Xilinx UltraScale+ PCIe IP**'sinin yerine konan
SystemVerilog VIP. v1.0.2 ile düz "mesaj listesi" yerine **senaryo dosyası** desteği geldi:
TLP göndermenin yanında *huzme başı (HB) bekle*, *süre bekle* ve *sonraki HB'yi planla*
komutlarını çalıştırır.

Ayrıntılı mimari için: **[ARCHITECTURE.md](ARCHITECTURE.md)**

## Hızlı başlangıç

1. Dosyaları Vivado'ya **simulation source** olarak ekle (tip: SystemVerilog, kütüphane: `xil_defaultlib`).
   Derleme sırası:
   ```
   src/axis_tx_if.sv  ->  src/beam_if.sv  ->  src/scn_pkg.sv  ->  src/sim_model_cpu.sv
   ```
2. `PcieTop.vhd` içindeki eski `gen_sim_model_cpu` bloğunu `docs/sim_model_cpu_inst.vhd` ile değiştir.
3. Senaryo dosyasını simülasyon çalışma dizinine `input_data.txt` adıyla koy
   (ya da `+TLP_FILE=<yol>` ver). Örnek: `examples/scenario_example.txt`.
4. Üst seviye testbench: `tb/tb_system_top.vhd` (veya `.sv`). `design_1_wrapper` testi için `tb/tb_top.sv`.

## Senaryo dosyası formatı (özet)

| Satır | Anlamı |
|---|---|
| `ADRES MSGID LEN BYTE0 BYTE1 ...` | TLP gönder (ADRES, MSGID hex; LEN onluk bayt sayısı, 4'ün katı) |
| `99999999` | Huzme başını bekle |
| `88888888 <ns>` | `<ns>` nanosaniye bekle |
| `77777777 <ns>` | `<ns>` sonra huzme başı üret (beklemez, arka planda) |
| `# ...` veya `// ...` | Yorum |

İlk alan `99999999`, `88888888` veya `77777777` ise satır **komuttur**, TLP değildir.
Bu üç değer gerçek TLP adresi olarak **kullanılmamalıdır**.

## Önemli parametreler (`sim_model_cpu`)

| Parametre | Varsayılan | Anlamı |
|---|---|---|
| `INPUT_FILE` | `"input_data.txt"` | Senaryo dosyası (`+TLP_FILE=` ile ezilir) |
| `BEAM_SOURCE` | `"SCRIPT"` | `"SCRIPT"`: HB'yi VIP üretir. `"DESIGN"`: gerçek modül üretir (`+BEAM_SOURCE=` ile ezilir) |
| `BEAM_PULSE_CLKS` | `1` | Üretilen HB darbesinin genişliği (clock) |
| `BEAM_ACTIVE_HIGH` | `1` | HB aktif-yüksek mi |
| `CQ_KEEP_WIDTH`, `RQ_KEEP_WIDTH` | `8` | `tkeep` genişlikleri |

## Test durumu (dürüst not)

- Ayrıştırıcı (parser), `77777777`/`99999999`/`88888888` mantığı ve hata satırı yönetimi
  **Verilator 5.020** ile bir mini testbench üzerinde koşturuldu ve beklenen zamanlamayı verdi.
- `driver`'ın AXI-S sürme kısmı ve `sim_model_cpu` **derlenip koşturulmadı** (ortamda Vivado/xsim yok;
  Verilator sanal arayüz kısıtı nedeniyle bu kısmı kabul etmedi). İlk Vivado derlemesinde
  küçük hatalar çıkabilir.

## v1.0.1'den farklar
- `cq_vip_pkg` -> `scn_pkg` (senaryo komutları, `beam_ctrl` eklendi).
- `sim_model_cpu` yeni portlar: `huzme_basi_obs` (giriş), `huzme_basi_gen` (çıkış).
- v1.0.1 formatındaki dosyalar (sadece TLP satırları) aynen geçerlidir.
