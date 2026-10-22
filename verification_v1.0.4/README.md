# PCIe + Aurora VIP - v1.0.4

Radar sistemi sinyal işleme FPGA'sını (sifpga) doğrulamak için, gerçek IP'lerin yerine konan SystemVerilog /
Verilog VIP seti. **Verif projesi sentezlenmez**; yalnızca simülasyon içindir.

| VIP | Yerine geçtiği IP | Rol |
|---|---|---|
| `sim_model_cpu` (SV) | PCIe UltraScale+ | İşlemci gibi davranır: senaryodaki TLP'leri sürer, FPGA'nın yazdığı TLP'leri **4 circular buffer**'a alır, MSI vektörüne göre okuyup **buffer başına ayrı dosyaya** yazar |
| `aurora_64b66b_vip` (Verilog) | Aurora 64B/66B (3 lane, UFC) | **Gözlemci**: link/saat/reset modeli üretir, FPGA'nın UFC ve kullanıcı verisini ham olarak log'lar. Cevap üretmez |

Ayrıntılı mimari: **[ARCHITECTURE.md](ARCHITECTURE.md)**

## v1.0.4'te neler değişti

PCIe tarafı (v1.0.3'e göre):
1. **BAR ID**: senaryo satırında `ADRES [BAR<n>] MSGID LEN DATA...` (yoksa BAR0). Descriptor DW3[18:16]'ya yazılır. BAR aperture kullanılmaz.
2. **4 buffer**: `1DEA0001` mesajı SIFPGA, SHOB1, SHOB2, IÜB buffer'larını programlar (aşağıda). `size = 0` → buffer kapalı (hata değil).
3. **Vektör tabanlı ISR**: `cfg_interrupt_msi_int` vektörünün hangi biti set ise yalnızca o buffer okunur.
4. **Ayrı çıktı dosyaları**: `cpu_out_sifpga.txt`, `cpu_out_shob1.txt`, `cpu_out_shob2.txt`, `cpu_out_iub.txt`.
   (`OUT_FILE` parametresi kalktı, yerine `OUT_PREFIX` geldi.)
5. RSI kesmeleri (bit 4, 5) **henüz uygulanmadı**: `msi_sent` yine döner, ISR "yok sayıldı" yazar.

Yeni: **Aurora gözlemci VIP** (`src/aurora_64b66b_vip.v`).

## MSI vektörü ve BAR eşlemesi

| MSI biti | Buffer | BAR (CPU→FPGA) |
|---|---|---|
| 0 (`0b000001`) | SIFPGA | BAR0 |
| 1 (`0b000010`) | SHOB1 | BAR2 |
| 2 (`0b000100`) | SHOB2 | BAR3 |
| 3 (`0b001000`) | IÜB | BAR1 |
| 4, 5 | RSI | (henüz yok) |

BAR numarası senaryoda satır satır **sen** verirsin; VIP BAR'a göre bir şey yapmaz, yalnızca descriptor'a yazar.
`ISR_ALL_BUFFERS=1` verilirse vektör ne olursa olsun 4 buffer da okunur (eski v1.0.3 davranışına yakın; hata ayıklama için).

## `1DEA0001` konfigürasyon mesajı (96 veri baytı, little-endian)

| Veri baytları | Buffer |
|---|---|
| `[0..23]` | SIFPGA: base (8B), size (8B), pointer adresi (8B) |
| `[24..47]` | SHOB1 (aynı düzen) |
| `[48..71]` | SHOB2 |
| `[72..95]` | IÜB |

Fazla baytlar yok sayılır. Mesaj 24 baytın katları kadar kısaysa kalan buffer'lar kapalı kalır
(en az 24 bayt = yalnızca SIFPGA; eski v1.0.3 örneği bu yüzden çalışır). Örnek: `examples/scenario_v104.txt`.

## Hızlı başlangıç - PCIe

1. Dosyaları Vivado'ya **simulation source** olarak ekle. Derleme sırası:
   ```
   src/axis_tx_if.sv -> src/beam_if.sv -> src/cpu_pkg.sv -> src/scn_pkg.sv -> src/sim_model_cpu.sv
   ```
2. `PcieTop.vhd`'deki instantiation'ı `docs/sim_model_cpu_inst.vhd` ile değiştir (port değişikliği yok).
3. Senaryo dosyasını çalışma dizinine `input_data.txt` olarak koy (`+TLP_FILE=<yol>` ile de verilebilir).
4. Simülasyon sonunda: `cpu_out_<buffer>.txt` dosyaları ve `rq_trace.txt`.

### Senaryo dosyası

| Satır | Anlamı |
|---|---|
| `ADRES [BAR<n>] MSGID LEN BYTE0 BYTE1 ...` | TLP gönder (ADRES, MSGID hex; LEN onluk bayt sayısı, 4'ün katı; `BAR0..BAR6`, büyük/küçük harf) |
| `99999999` | Huzme başını bekle |
| `88888888 <ns>` | `<ns>` nanosaniye bekle |
| `77777777 <ns>` | `<ns>` sonra huzme başı üret (beklemez) |
| `# ...` / `// ...` | Yorum |

Her `99999999`'dan önce onu üretecek bir `77777777` olmalı (SCRIPT modunda), yoksa senaryo kilitlenir.

### `sim_model_cpu` parametreleri

| Parametre | Varsayılan | Anlamı |
|---|---|---|
| `INPUT_FILE` | `"input_data.txt"` | Senaryo (`+TLP_FILE=`) |
| `BEAM_SOURCE` | `"SCRIPT"` | `"SCRIPT"` / `"DESIGN"` (`+BEAM_SOURCE=`) |
| `BEAM_PULSE_CLKS` / `BEAM_ACTIVE_HIGH` | `1` / `1` | HB darbe genişliği / polarite |
| `OUT_PREFIX` | `"cpu_out"` | Çıktı dosyası ön eki (`+CPU_OUT=`) → `<önek>_sifpga.txt` ... |
| `TRACE_FILE` | `"rq_trace.txt"` | Tüm TLP/ISR izi (`+RQ_TRACE=`) |
| `ISR_LATENCY_NS` | `100` | MSI'dan ISR'ye bekleme |
| `ISR_ALL_BUFFERS` | `0` | `1`: vektöre bakmadan 4 buffer'ı da oku |
| `CFG_MSG_ID` | `32'h1DEA0001` | Buffer'ları programlayan mesaj ID'si |
| `CFG_/PTR_/MSG_BIG_ENDIAN` | `0` | 0 = little-endian |

## Aurora gözlemci VIP - entegrasyon

Dosya: `src/aurora_64b66b_vip.v` (düz Verilog-2001, tek dosya, SV gerekmez).

1. Dosyayı projeye **simulation source** olarak ekle. Simulation set → Verilog Options → **`VIP_BEHAVIORAL=1`** tanımla.
   (Tanımsızsa modül sade bir gövdeyle derlenir: BD'nin modülü ayrıştırması için; davranış yoktur.)
2. Block Design'da `shob_1_aurora_gth` ve `shob_2_aurora_gth` hücrelerini sil; yerine **Add Module** ile
   `aurora_64b66b_vip`'i ekle ve aynı adları ver. Her hücrede `UNIT_NAME` parametresini ayarla
   (`"shob_1"`, `"shob_2"`) → `aurora_obs_shob_1.txt` / `aurora_obs_shob_2.txt` üretilir.
3. Portlar orijinal `Aurora_aurora_64b66b_0_0` ile birebir aynıdır. `USER_DATA_S_AXIS_TX`, `USER_DATA_M_AXIS_RX`,
   `UFC_S_AXIS_TX`, `UFC_M_AXIS_RX` standart AXI-Stream olarak, `gt_refclk1_p/n` ise `GT_DIFF_REFCLK1` (diff_clock, 250 MHz) olarak gruplanır; `user_clk_out` saati bu arayüzlerle
   ilişkilendirilir (`FREQ_HZ=125000000`). `CORE_CONTROL` (gt_rxcdrovrden_in, loopback, power_down), `CORE_STATUS` (channel_up, lane_up, hard_err, soft_err,
   crc_pass_fail, crc_valid, gt_pll_lock, pll_not_locked_out), `GT_SERIAL_RX` (rxp, rxn) ve `GT_SERIAL_TX` (txp, txn)
   gerçek IP'den alınan VLNV'lerle paketlenmiştir (`display_aurora:core_control_in`, `core_status_out`,
   `GT_Serial_Transceiver_Pins_RX/TX`). Port-arayüz eşlemesi `Top.vhd`'deki `aurora_wrapper` port map'inden çıkarıldı.
   Arayüz içindeki mantıksal sinyal adlarının **büyük/küçük harf yazımı tahmindir**; BD'de doğrulayın.
   Gruplanmayan portlar (pma_init, reset_pb, gt_powergood, sys_reset_out vb.) düz pin kalır.

**SystemVerilog alternatifi:** `alt/aurora_64b66b_vip.sv` aynı modül adı, port ve davranışa sahiptir
(`string/int` parametre, `logic`, `always_ff`, `$sformatf`). **İkisinden yalnızca birini** projeye ekleyin
(modül adı çakışır). Önce `.sv` denenebilir; BD module reference olarak kabul etmezse `src/aurora_64b66b_vip.v` kullanılır.
Cevap verme aşamasında sınıf/kuyruk gerekeceği için gelecekteki taban `.sv` sürümüdür. Aynı test ikisini de doğrular.

### Davranış (gözlemci)

| Konu | Davranış |
|---|---|
| `user_clk_out` (= `sync_clk_out` = `tx_out_clk`) | 125 MHz |
| Link | Reset serbestken: `gt_powergood` (5 clk) → `gt_pll_lock` (8) → `gt_reset_out` biter (10) → `sys_reset_out` biter (20) → `channel_up`/`lane_up=111` (`LINK_UP_CLKS`=625 clk ≈ 5 µs). `reset_pb`, `pma_init`, `power_down` linki düşürür |
| `s_axi_tx_tready` | Her zaman 1 |
| UFC TX | `ufc_tx_req` yükselen kenarında istek alınır (`ufc_tx_ms` = bayt-1, 24 baytlık beat'lere bölünür; ms=3 → 1 beat), beat'ler bitene kadar `s_axi_ufc_tx_tready=1`. Ham 192 bit `tdata` log'lanır |
| RX / UFC RX | Boş (`tvalid=0`, `ufc_in_progress=0`); **cevap üretilmez** |
| Kullanıcı verisi | Yalnızca **alt 128 bit** log'lanır (+ `tkeep`, `tlast`) |

Log örneği (`aurora_obs_<birim>.txt`, zamanlar ns):
```
5004 LINK channel_up=1 lane_up=111
5004 UFC_REQ ms=3 (4 bayt)
5012 UFC_TX tdata=0000...cafef00d
5132 USER_TX lo128=00112233445566778899aabbccddeeff keep=00ffff last=1
```

## Test

```bash
./test/run_verilator.sh      # Verilator >= 5.0 gerekir
```

| Test | Neyi doğrular |
|---|---|
| `tb/tb_cpu_check.sv` | Tek buffer (SIFPGA): birleşmiş/sahte kesme, sarma, bölünmüş yazma, pointer varyasyonları (11 mesaj) |
| `tb/tb_multi_check.sv` | **4 buffer**, MSI vektörüne göre yönlendirme (yalnız set bit okunur), RSI yok sayma, SHOB2 sarma, ayrı dosyalar |
| `tb/tb_cq_check.sv` | CPU→FPGA TLP baytları, tkeep/tuser, HB/bekleme zamanlaması, **BAR ID (`BAR2`, `bar5`, varsayılan BAR0)** |
| `tb/tb_fill_check.sv` | Buffer doldurma / sarma / taşma tespiti |
| `tb/tb_aurora_check.sv` | Aurora VIP: 125 MHz, link sırası, UFC el sıkışması, RX boş, log içeriği, `reset_pb` ile yeniden link |

## Test durumu (dürüst not)

- Doğrulandı: Verilator 5.020'de beş test de geçiyor.
- **Doğrulanmadı:** Vivado/xsim derlemesi, VHDL karma dil entegrasyonu, `tb_system_top`/`tb_top`, BD'de
  module reference olarak eklenme ve arayüz gruplaması.
- **Varsayımlar (gerçek IP ile karşılaştırılmadı):** UFC TX el sıkışması (`ufc_tx_ms` = bayt-1, tready'nin
  `ufc_tx_req` sonrası verilmesi), link süreleri, resetlerin aktif-yüksek olması. Gerçek davranış farklıysa
  log'lar ham olduğu için kayıp olmaz; sadece zamanlama/ready modeli güncellenir.
- Pointer değeri = buffer içi mutlak adres (bir sonraki boş bayt); FPGA mesajındaki `len` sadece veri baytı.

## Sürümler
- `verification_v1.0.2/`: CPU→FPGA, senaryo + HB.
- `verification_v1.0.3/`: + FPGA→CPU işlemci modeli (tek buffer).
- `verification_v1.0.4/` (bu klasör): BAR ID, 4 buffer + MSI vektörü, ayrı dosyalar, Aurora gözlemci VIP.
