# v1.0.7 - Ne değişti? (özet)

Bu sürüm, v1.0.5'in üstüne **hüzme verisi akışını** ekler: SHOB'lar hüzme verisini SİFPGA'ya basar, RSİ'ler
(radar sinyal işleme işlemcileri) SİFPGA'nın PCIe ile yazdığı veriyi alıp doğrular. Mevcut her şey (CPU modeli,
CİT/HUZPAR cevapları, otomatik TLP bölme, IÜB) aynen çalışır; yalnızca **eklemeler** ve iki küçük **davranış değişikliği** var.

## Yeni / değişen dosyalar

| Dosya | Durum | Ne yapıyor |
|---|---|---|
| `src/aurora_64b66b_vip.v` | **değişti** | `0000E001` (HUZPAR) alınınca, `DATA_DELAY_CLKS` sonra **hüzme verisi (`00000002`)** gönderir (192 bit `m_axi_rx_*`). Bkz. `docs/SHOB_HUZME_VERISI.md` |
| `src/sim_model_rsi.sv` | **yeni** | RSİ işlemci modeli (RSİ1/2/3 için ayrı örnek). Bkz. `docs/RSI_MODELI.md` |
| `src/cpu_pkg.sv` | **değişti (küçük)** | Yalnızca **MSI7 (bit 6)** etiketi ve `msi7_count` |
| `src/rsi_pkg.sv` | **yeni** | Paylaşılan RSİ durumu (`rsi_start_addr`, `turlar`, tur raporu), `track_cfg_msgs`. `cpu_pkg`'den ayrıldı (RSİ kullanılmıyorsa projeye eklenmeyebilir) |
| `src/scn_pkg.sv` | **değişti** | Sürücü her TLP'yi `rsi_pkg::track_cfg_msgs`'e de verir; **yalnızca `VIP_RSI` tanımlıysa derlenir** (1 satır) |
| `tools/gen_huzme_rounds.py` | **yeni** | Çok turlu senaryo üretici. Bkz. `docs/SENARYO_URETICI.md` |
| `examples/input_huzme_turlari.txt` | **yeni** | 3 turlu hazır senaryo (adres atama + 3 tur) |
| `examples/scenario_huzme_test.txt` | **yeni** | Test senaryosu (2 tur, küçük) |
| `docs/sim_model_rsi_inst.vhd` | **yeni** | RSİ modelini Top'a SIM_MODE ile ekleme şablonu (**siz** ekleyeceksiniz) |
| `tb/tb_shob_data_check.sv` | **yeni** | SHOB veri göndericisi testi |
| `tb/tb_rsi_check.sv` | **yeni** | RSİ modelleri testi (3 RSİ, 4 tur, hata yakalama) |
| `tb/tb_scn_rsi_check.sv` | **yeni** | Senaryo → sürücü → paylaşılan RSİ durumu zinciri testi |
| `test/run_verilator.sh` | **değişti** | Yeni testler eklendi, sürüm 1.0.7 |

**Dokunulmayanlar:** `Top.vhd` / `PcieTop.vhd` (tasarımcıya ait; RSİ modelini siz ekleyeceksiniz),
`sim_model_cpu.sv` (yalnızca sürüm yazısı), Aurora 8b10b VIP (yalnızca sürüm yazısı).

## Davranış değişiklikleri (eski çıktıyı etkileyebilir)

1. **SHOB VIP artık `m_axi_rx_*` üzerinde veri sürüyor.** Eskiden bu portlar sabit 0'dı. Her `0000E001` mesajı için
   (darbe sayısı > 0 ise) tek bir `00000002` mesajı gelir. Eski davranışa dönmek için: `DATA_ENABLE => 0`.
2. **MSI vektörünün bit 6'sı artık "MSI7" olarak raporlanır** ve `unknown_msi` sayacına girmez
   (daha önce "tanımsız MSI bit" uyarısı veriyordu). `cpu_out_*` dosyalarının içeriği değişmez; yalnızca
   `rq_trace.txt`'teki ISR satırı `bit6..0=` yazar ve MSI7 satırı eklenir.

## Bu sürümde YAPILMAYANLAR (bilinçli)

- Hata enjeksiyonu: "SHOB verisi eksik gönderme / hiç göndermeme" (MSI3 / MSI4) yok. RSİ modeli bu bitleri
  görürse yalnızca log'a yazar.
- RSY tarafına ek kesme (MSI5/6, `1DEA001B` Huzme Veri Durum) yok.
- HB, SHOB VIP'e verilmez (standart Aurora IP'sinde HB girişi yok); veri gönderimi HUZPAR + sabit gecikmeyle tetiklenir.

## Test

```bash
./test/run_verilator.sh        # Verilator >= 5.0, python3
```

Çalıştırılan testler: `tb_cpu_check`, `tb_multi_check`, `tb_cq_check`, `tb_fill_check`, `tb_aurora_check`,
`tb_aurora8b_check` (eskiler), **`tb_shob_data_check`, `tb_rsi_check`, `tb_scn_rsi_check`** (yeni).
Hepsi geçince `HEPSI GECTI` yazar. Vivado xsim 2020.2 ile **çalıştırılmadı** (bu ortamda yok); yeni SV kodunda
xsim'in sevmediği bilinen kalıplardan kaçınıldı ama ilk derlemede küçük bir uyumsuzluk çıkarsa haber verin.

## xsim'de RSİ'siz kullanım (v1.0.7 düzeltmesi)

v1.0.7'nin ilk halinde RSİ durumu `cpu_pkg.sv` içindeydi ve Vivado xsim 2020.2'de elaborate sırasında `EXCEPTION_ACCESS_VIOLATION` verdi
(`cpu_pkg.sv` + `scn_pkg.sv` v1.0.5'e dönülünce çözüldü). Bu yüzden RSİ kodu **ayrı pakete** (`rsi_pkg.sv`) taşındı:

- **RSİ'siz kullanım:** `rsi_pkg.sv` ve `sim_model_rsi.sv` projede **olmasın**; `VIP_RSI` tanımlama. `cpu_pkg.sv` v1.0.5'ten yalnızca MSI7 etiketiyle ayrılır.
- **RSİ'li kullanım:** `rsi_pkg.sv` ve `sim_model_rsi.sv`'yi ekleyin, `sim_1` ayarlarında `verilog_define` olarak `VIP_RSI` tanımlayın
  (`set_property verilog_define {VIP_RSI} [get_filesets sim_1]`), derleme sırası: `cpu_pkg`, `rsi_pkg`, `scn_pkg`.
- Çökmenin hangi satırdan kaynaklandığı **bilinmiyor** (xsim bu ortamda yok). İlişkisel dizi iç içeliği azaltıldı; yine çökerse `rsi_pkg.sv`
  içinde aranır.
