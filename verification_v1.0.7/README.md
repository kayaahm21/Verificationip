# PCIe + Aurora VIP - v1.0.7

Radar sistemi sinyal işleme FPGA'sını (sifpga) doğrulamak için, gerçek IP'lerin yerine konan SystemVerilog /
Verilog VIP seti. **Verif projesi sentezlenmez**; yalnızca simülasyon içindir.

| VIP | Yerine geçtiği IP | Rol |
|---|---|---|
| `sim_model_cpu` (SV) | PCIe UltraScale+ | İşlemci gibi davranır: senaryodaki TLP'leri sürer, FPGA'nın yazdığı TLP'leri **4 circular buffer**'a alır, MSI vektörüne göre okuyup **buffer başına ayrı dosyaya** yazar |
| `aurora_64b66b_vip` (Verilog) | Aurora 64B/66B (3 lane, UFC) | **Gözlemci**: link/saat/reset modeli üretir, FPGA'nın UFC ve kullanıcı verisini ham olarak log'lar. Cevap üretmez |
| `aurora_8b10b_vip` (Verilog) | Aurora 8b/10b (IÜB, 1 lane, 32 bit, UFC yok) | Aynı gözlemci mantığı; DRP portu yok |
| `sim_model_rsi` (SV, **v1.0.7**) | PCIe (RSİ1/2/3 tarafı) | RSİ işlemci modeli: hüzme verisini (float32 I/Q) alır, MSI1/MSI2'de çözer, doğrular, txt'ye döker |

Ayrıntılı mimari: **[ARCHITECTURE.md](ARCHITECTURE.md)**

## v1.0.7'de yeni: hüzme verisi akışı (SHOB → SİFPGA → RSİ)

- **SHOB VIP** (`aurora_64b66b_vip`) her `0000E001` HUZPAR'ından ~5 µs sonra **hüzme verisini (`00000002`)** `m_axi_rx_*` üzerinden (192 bit,
  kısmi son beat `tkeep`) basar; her örnek kendini tarif eden desendir. -> **[docs/SHOB_HUZME_VERISI.md](docs/SHOB_HUZME_VERISI.md)**
- **RSİ modeli** (`sim_model_rsi`, RSİ1/2/3 için ayrı örnek) SİFPGA'nın PCIe ile yazdığı veriyi alır; MSI1/MSI2'de adres, desen,
  birleştirme kuralı (toplam?), yerleşim, eksiksizlik ve hüzme sayısını kontrol eder, `rsi_out_rsi<N>.txt` ve `rsi_tur_ozeti.txt` yazar.
  -> **[docs/RSI_MODELI.md](docs/RSI_MODELI.md)**
- **CPU VIP** `1DEA0001`/`1DEA0003` mesajlarını sürerken RSİ adresi/offset/hüzme sayılarını RSİ modellerine paylaşır; MSI vektörünün
  **bit 6'sı MSI7** olarak etiketlenir (artık "tanımsız" uyarısı yok).
- **Çok turlu senaryo üretici:** `tools/gen_huzme_rounds.py` -> **[docs/SENARYO_URETICI.md](docs/SENARYO_URETICI.md)**; hazır örnek: `examples/input_huzme_turlari.txt`.
- **RSİ'yi Top'a ekleme (siz yapacaksınız):** `docs/sim_model_rsi_inst.vhd`.
- Ne değişti / varsayımlar / açık sorular: **[docs/V1_0_7_DEGISIKLIKLER.md](docs/V1_0_7_DEGISIKLIKLER.md)**,
  **[docs/VARSAYIMLAR_VE_ACIK_SORULAR.md](docs/VARSAYIMLAR_VE_ACIK_SORULAR.md)**.

Eski davranışa dönmek için: SHOB VIP'te `DATA_ENABLE => 0`; MSI7 yalnızca etiket değişikliğidir.

## v1.0.5'te yeni: SHOB CİT cevabı (Aurora 64b66b VIP)

`aurora_64b66b_vip` artık yalnızca gözlemci değil. FPGA'dan UFC ile gelen **`0000E003` (CİT isteği, LEN=0)** mesajına
**1 µs sonra `0000E004` (LEN=184)** cevabını UFC RX üzerinden verir. Diğer mesaj ID'leri yok sayılır
(log'a `UFC_MSG yok sayildi` yazılır).

**Mesaj akışı (TX'in aynası):** Her 4 baytlık kelime ayrı bir UFC mesajıdır. FPGA'dan gelen istek iki kelimedir
(`ID`, `LEN`); VIP bunları birleştirir. Cevap 48 kelimedir: kelime0 = `0000E004`, kelime1 = `184`, sonra 46 veri kelimesi.
Her kelime `m_axi_ufc_rx_*` üzerinde bir clock'luk bir beat'tir (`tdata[31:0]`, `tkeep=0xF`, `tlast=1`); kelimeler arası
`RESP_GAP_CLKS` (varsayılan 1) boş clock. Beat sırasında `ufc_in_progress` "işlemde" seviyesine gider
(active-low varsayımı: 0).

**Cevap gövdesi (184 bayt) = 4 blok × 46 bayt:**

| Blok içi | Boyut | Alan |
|---|---|---|
| +0..7 | 8 B | 0 |
| +8..21 | 14 B | sıcaklıklar, `int8` (°C) |
| +22..25 | 4 B | cihaz saati, `uint32` (saniye) |
| +26..41 | 16 B | 8 × `uint16`: **[0] akım (mA)**, **[1..7] gerilim (mV)** |
| +42..45 | 4 B | reserved (0) |

Varsayılan değerler (gerçekçi, sabit): sıcaklıklar 35–54 °C (blok `k` için `+k`), akım `1250 + 150·k` mA, gerilimler
12000/5000/3300/2500/1800/1200/1000 mV (blok `k` için `−5·k`). Cihaz saati = `UPTIME_OFFSET_S` + simülasyon süresi (saniye).

**Parametreler (BD'de hücrede):**

| Parametre | Varsayılan | Anlamı |
|---|---|---|
| `RESP_ENABLE` | 1 | 0: cevap üretme (yalnızca gözlemci) |
| `RESP_DELAY_CLKS` | 125 | İstekten ilk kelimeye bekleme (125 clk = 1 µs) |
| `RESP_GAP_CLKS` | 1 | Kelimeler arası boş clock |
| `FIELD_BIG_ENDIAN` | 0 | `uint16`/`uint32` alanları (0 = little-endian) |
| `WORD_BIG_ENDIAN` | 0 | 4 baytlık kelime paketleme (0: ilk bayt `tdata[7:0]`) |
| `UPTIME_OFFSET_S` | 273600 | Cihaz saati başlangıcı (saniye) |

**Varsayımlar (doğrulanmadı):** bayt sırası little-endian (bilinmiyor); 3. blokta da saat var (tarifte atlanmıştı, 4×46=184
bunu gerektiriyor); UFC RX kelimelerinin art arda 4 baytlık mesaj olarak, `tready` beklenmeden verilmesi; `ufc_in_progress`
active-low. Kontrolcü cevabı almazsa önce `RESP_GAP_CLKS`, `WORD_BIG_ENDIAN` ve `ufc_in_progress` ile oynayın.

Log'a yeni satırlar: `UFC_MSG id=… len=…`, `UFC_RESP planlandi …`, `UFC_RX idx=… word=…`, `UFC_RESP bitti …`.

**Not:** v1.0.5'te SystemVerilog alternatifi (`alt/`) yoktur; `.sv` sürümü yalnızca v1.0.4'tedir (gözlemci).
8b10b VIP (IÜB) değişmedi.

## v1.0.4'te neler değişti (v1.0.3'e göre)

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

## `1DEA0001` konfigürasyon mesajı (LEN=124; ilk 96 veri baytı kullanılır, little-endian)

| Veri baytları | Buffer |
|---|---|
| `[0..23]` | SIFPGA: base (8B), size (8B), pointer adresi (8B) |
| `[24..47]` | SHOB1 (aynı düzen) |
| `[48..71]` | SHOB2 |
| `[72..95]` | IÜB |

`[96..123]` baytları (toplam LEN=124) şimdilik yok sayılır; satırdaki bayt sayısı yine `LEN` ile tutmalıdır. Mesaj 24 baytın katları kadar kısaysa kalan buffer'lar kapalı kalır
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
| `ADRES [BAR<n>] MSGID LEN BYTE0 BYTE1 ...` | TLP gönder (ADRES, MSGID hex; LEN onluk bayt sayısı, 4'ün katı; `BAR0..BAR6`, büyük/küçük harf). **Otomatik bölme (v1.0.5):** mesaj (ID+LEN+veri) **32 DWORD'dan (128 bayt) büyükse** 32 DWORD'luk paketlere bölünüp her biri ayrı TLP olarak art arda gönderilir; `ID+LEN` yalnızca ilk pakette, adres tüm paketlerde aynı, son paket kısa olabilir. Küçük mesajlar tek TLP'dir, **32'ye tamamlama/dolgu yoktur**. Sınır `MAX_TLP_DWORDS` parametresiyle değişir (0: bölme yok; bu durumda LEN ≤ 8192). Bölme açıkken LEN sınırı 1 MB |
| `99999999` | Huzme başını bekle |
| `88888888 <ns>` | `<ns>` nanosaniye bekle |
| `77777777 <ns>` | `<ns>` sonra huzme başı üret (beklemez) |
| `# ...` / `// ...` | Yorum |

Her `99999999`'dan önce onu üretecek bir `77777777` olmalı (SCRIPT modunda), yoksa senaryo kilitlenir.

### SHOB HUZPAR ve KATSAYILAR (`0000E001`) senaryosu (v1.0.5)

PCIe'den SHOB'a gidecek hüzme parametre mesajı **32 DWORD'lük (128 bayt) paketlere bölünerek** gönderilir
(tasarımcının isteği; senaryoda özel bir alan gerekmez, **otomatik bölme**; varsayımlar: `ID+LEN` yalnızca ilk pakette, adres hep 0, paketler art arda, son paket kısa).
SHOB-1 **BAR1**, SHOB-2 **BAR2** (ICD). Mesaj yapısı (56 bayt başlık + katsayılar, hepsi little-endian):
huzme ID (4), sinyal işleme durumu (2; 0 Bypass, 1 HO), alma huzmesi sayısı (2), darbe sayısı (4), darbedeki örnek sayısı (4),
4 × GAÇ kullanım maskesi (4'er), kart kullanım durumu (1), test modu (1), reserved (22); ardından HO'da
`M × 120 GAÇ × 4 kanal × (I,Q) × int16` = M×1920 bayt katsayı (Bypass'ta katsayı yok, LEN=56).

- Örnek senaryo: `examples/input_shob_huzpar.txt` (HO, M=4, darbe=4, örnek=4; LEN=7736 → 61 paket; SHOB-1 ve SHOB-2).
- Üretici: `tools/gen_shob_huzpar.py` (`--bar`, `--mode ho|bypass`, `--m`, `--pulses`, `--samples`, `--huzme-id`, `--gac-masks`,
  `--card`, `--test-mode`). Katsayılar rastgele int16 (sabit tohum).
- Katsayı sırası (ICD): **Huzme → GAÇ (1..120) → Kanal (1..4) → I, Q**, hepsi `int16`, 56. bayttan başlar.
- SHOB VIP bu mesajı **gözlemler** (cevap üretmez); ayrıntılar aşağıdaki "SHOB HUZPAR gözlemi" bölümünde.


### SHOB HUZPAR gözlemi (v1.0.5)

`s_axi_tx_*` (192 bit) üzerinden gelen kullanıcı verisi mesaj olarak birleştirilir: her beat'te yalnızca **alt 128 bit**
(`tkeep[15:0]`, 16 bayt) geçerlidir, **üst 64 bit için `tkeep=0`** beklenir (aksi halde uyarı). Beat'ler `tlast`'a kadar toplanır;
biçim `ID (4 B) + LEN (4 B, yalnızca veri) + veri`. Her mesaj için obs dosyasına `MSG id=… len=… data=…` satırı yazılır.
ID **`0000E001`** ise ayrıca (birim adı = `UNIT_NAME`, ör. `shob_1`):

| Dosya | İçerik |
|---|---|
| `aurora_huzpar_<UNIT_NAME>.txt` | Mesaj başına bir satır: `huzme_id`, `durum` (Bypass/HO), `alma_huzme`, `darbe`, `ornek`, `gac_maske` (4 × hex), `kart`, `test_modu`, `katsayi_int16`, `reserved`; altında doğrulama uyarıları |
| `aurora_huzpar_katsayi_<UNIT_NAME>.txt` | HO'da (huzme, GAÇ) başına bir satır: `huzme=1 gac=1 k1 I=… Q=… k2 I=… Q=… k3 … k4 …` (işaretli `int16`) |

Örnek (`aurora_huzpar_shob_1.txt`):
```
14084 HUZPAR id=0000e001 len=7736 huzme_id=0000ab12 durum=HO alma_huzme=4 darbe=4 ornek=4 gac_maske=3fffffff,00000001,20000000,15555555 kart=01 test_modu=0 katsayi_int16=3840 reserved=00 00 ... 00
```

**Doğrulamalar (`HUZPAR_UYARI`):** `LEN` ≠ `56 + M×1920` (Bypass'ta ≠ 56); durum 0/1 değil; HO'da alma huzmesi 4..96 (4'er adım) değil, Bypass'ta 960 değil;
Bypass'ta katsayı gelmesi; darbe sayısı 0; örnek sayısı 0 ya da 4'ün katı değil; GAÇ maskelerinde bit 30/31 set; test modu 1 iken HI kullanımı (kart bit1–3) set;
reserved alanı sıfır değil; üst 64 bit `tkeep=1`; mesaj 64 bayttan kısa; katsayılar eksik.

**Parametreler:** `MAX_MSG_BYTES` (262144; HO M=96 için 184384 bayt gerekir), `LOG_RAW_BEATS` (1; büyük mesajda `USER_TX` satırlarını kapatmak için 0),
`LOG_DATA_BYTES` (64; obs'taki `MSG` satırına yazılan en fazla veri baytı).


### `sim_model_cpu` parametreleri

| Parametre | Varsayılan | Anlamı |
|---|---|---|
| `INPUT_FILE` | `"input_data.txt"` | Senaryo (`+TLP_FILE=`) |
| `BEAM_SOURCE` | `"SCRIPT"` | `"SCRIPT"` / `"DESIGN"` (`+BEAM_SOURCE=`) |
| `BEAM_PULSE_CLKS` / `BEAM_ACTIVE_HIGH` | `1` / `1` | HB darbe genişliği / polarite |
| `OUT_PREFIX` | `"cpu_out"` | Çıktı dosyası ön eki (`+CPU_OUT=`) → `<önek>_sifpga.txt` ... |
| `TRACE_FILE` | `"rq_trace.txt"` | Tüm TLP/ISR izi (`+RQ_TRACE=`) |
| `MAX_TLP_DWORDS` | `32` | CPU→FPGA paket başına en fazla DWORD; daha büyük mesajlar otomatik bölünür (0: bölme yok) |
| `ISR_LATENCY_NS` | `100` | MSI'dan ISR'ye bekleme |
| `ISR_ALL_BUFFERS` | `0` | `1`: vektöre bakmadan 4 buffer'ı da oku |
| `CFG_MSG_ID` | `32'h1DEA0001` | Buffer'ları programlayan mesaj ID'si |
| `CFG_/PTR_/MSG_BIG_ENDIAN` | `0` | 0 = little-endian |

## Aurora gözlemci VIP - entegrasyon

Dosya: `src/aurora_64b66b_vip.v` (düz Verilog-2001, tek dosya, SV gerekmez).

1. Dosyayı projeye **design source** olarak ekle (BD module reference için). Davranış **varsayılan olarak açıktır**, ekstra tanım gerekmez.
   (Yalnızca sade gövde istenirse `VIP_STUB` tanımlanır.)
2. Block Design'da `shob_1_aurora_gth` ve `shob_2_aurora_gth` hücrelerini sil; yerine **Add Module** ile
   `aurora_64b66b_vip`'i ekle ve aynı adları ver. Her hücrede `UNIT_NAME` parametresini ayarla
   (`"shob_1"`, `"shob_2"`) → `aurora_obs_shob_1.txt` / `aurora_obs_shob_2.txt` üretilir.
3. Portlar orijinal `Aurora_aurora_64b66b_0_0` ile birebir aynıdır. `USER_DATA_S_AXIS_TX`, `USER_DATA_M_AXIS_RX`,
   `UFC_S_AXIS_TX`, `UFC_M_AXIS_RX` standart AXI-Stream olarak, `gt_refclk1_p/n` ise `GT_DIFF_REFCLK1` (diff_clock, 250 MHz) olarak gruplanır; `user_clk_out` saati bu arayüzlerle
   ilişkilendirilir (`FREQ_HZ=125000000`). `CORE_CONTROL`, `CORE_STATUS`, `GT_SERIAL_RX/TX` Aurora'ya özgü arayüzleri **paketlenmemiştir**: bu portlar düz pindir
   (Vivado, bu özel arayüzleri bizim etiketlerle tanımadı). `Top.vhd`'nin beklediği `SHOB_1_CORE_STATUS_channel_up`
   gibi dış port adlarını üretmek için BD'de `tools/bd_externals_aurora.tcl` betiği kullanılır:
   ```
   source <yol>/tools/bd_externals_aurora.tcl
   make_aurora_externals shob_1_aurora_gth SHOB_1
   make_aurora_externals shob_2_aurora_gth SHOB_2
   ```
   Betik eski, boş kalmış arayüz dış portlarını siler ve her pin için düz dış port açar.

### Davranış (gözlemci)

| Konu | Davranış |
|---|---|
| `user_clk_out` (= `sync_clk_out` = `tx_out_clk`) | 125 MHz |
| Link | Reset serbestken: `gt_powergood` (5 clk) → `gt_pll_lock` (8) → `gt_reset_out` biter (10) → `sys_reset_out` biter (20) → `channel_up`/`lane_up=111` (`LINK_UP_CLKS`=625 clk ≈ 5 µs). `reset_pb`, `pma_init`, `power_down` linki düşürür |
| `s_axi_tx_tready` | Her zaman 1 |
| UFC TX | `ufc_tx_req` yükselen kenarında istek alınır (`ufc_tx_ms` = bayt-1, 24 baytlık beat'lere bölünür; ms=3 → 1 beat), beat'ler bitene kadar `s_axi_ufc_tx_tready=1`. Ham 192 bit `tdata` log'lanır |
| RX / UFC RX | Boş (`tvalid=0`); **cevap üretilmez**. `ufc_in_progress` boşta seviyesinde: varsayılan **1** (active-low varsayımı), `UFC_IN_PROGRESS_IDLE` parametresiyle 0 yapılabilir |
| Kullanıcı verisi | Yalnızca **alt 128 bit** log'lanır (+ `tkeep`, `tlast`) |

Log örneği (`aurora_obs_<birim>.txt`, zamanlar ns):
```
5004 LINK channel_up=1 lane_up=111
5004 UFC_REQ ms=3 (4 bayt)
5012 UFC_TX tdata=0000...cafef00d
5132 USER_TX lo128=00112233445566778899aabbccddeeff keep=00ffff last=1
```

## Aurora 8b10b VIP (IÜB): gözlem + HUZPAR cevabı

Dosya: `src/aurora_8b10b_vip.v`. Portlar `Aurora_aurora_8b10b_0_2` ile aynıdır, **DRP portları (`gt0_drp*`) yoktur**.
- `rxp/rxn/txp/txn/lane_up/gt_powergood` `[0:0]` vektördür (wrapper'daki `std_logic_vector(0 to 0)` ile uyumlu).
- `tx_out_clk` 125 MHz üretir (BD'deki BUFG_GT zinciri bunu kullanır). Link modeli dahili saatle çalışır; kullanıcı verisi (`s_axi_tx_*`) log'u **`user_clk`** girişiyle örneklenir (BD'de bu saat SHOB IP'sinin `user_clk_out`'undan gelir, `user_clk` ve `sync_clk` aynı düğüme bağlıdır). Bu yüzden SHOB VIP'i de aktif olmalıdır.
- Link sayacı `reset`/`gt_reset`/`power_down`'ın **yükselen kenarında** yeniden başlar (seviyeye bağlı değil: BD `reset`'i `sys_reset_out`'tan türetiyorsa kilitlenme olmasın).
- Log: `aurora8b10b_obs_<UNIT_NAME>.txt`.
- **v1.0.5: mesaj birleştirme.** `user_data_s_axis_tx` (32 bit) beat'leri `tlast`'a kadar toplanır; mesaj biçimi
  `ID (4 B) + LEN (4 B) + LEN bayt veri`. `tkeep`'te 1 olan baytlar sırayla alınır (ilk bayt `tdata[7:0]`; kısmi son beat
  desteklenir). ID ve LEN, ilk iki 32 bitlik kelimenin sayısal değeridir. Obs dosyasına her mesaj için bir satır yazılır:
  ```
  5100 MSG id=00001234 len=8 data=11 22 33 44 55 66 77 88
  5044 MSG id=0000e003 len=0 data=
  ```
  Ham beat satırları (`USER_TX data=… keep=… last=…`) de kalır. 8 bayttan kısa mesaj `MSG_KISA`, `LEN` ile gelen bayt sayısı
  uyuşmazsa `MSG_UYARI` yazılır. **Cevap üretilmez** (gözlemci); cevap sonraki adım.
- BD'de dış portlar için: `make_iub_externals aurora_8b10b_vip_0` (`tools/bd_externals_aurora.tcl`).
- Aurora'ya özgü arayüzler (CORE_CONTROL/CORE_STATUS/GT_SERIAL) 64b66b VIP'teki gibi **paketlenmemiştir** (düz pin); AXI-Stream arayüzleri `USER_DATA_S_AXIS_TX`/`USER_DATA_M_AXIS_RX` paketlidir.

### HUZPAR cevabı (v1.0.5)

IÜB'ye **`00000001` (HUZPAR isteği)** gelince **1 µs sonra `00000002` (HUZPAR cevabı)** `m_axi_rx_*` üzerinden
(32 bit, `tready` yok, beat'ler art arda) verilir. Diğer ID'lere cevap verilmez.

**İstek (`00000001`)**: `ID(4B) + LEN(4B, yalnızca veri) + veri`. Veri alanları:

| Alan | Boyut |
|---|---|
| huzme ID | 4 B |
| IÜB kontrol parametreleri | 28 + F B (F=0) |
| reserved | 8 B |
| ADK1 … ADK_M huzpar | M × (172·N + 20) B |

Beklenen `LEN = M·(172·N+20) + 40 + F`. Şimdilik **M=4, N=4** → **2872** B (tel üzerinde 2880 B = 720 beat). Radar için
M=10, N=24 → 41520 B; `M_ADK`/`N_CORE` parametreleriyle büyütülür (`MAX_MSG_BYTES` varsayılan 65536).
İçerik (kontrol parametreleri, ADK huzparları) VIP için önemli değildir; yalnızca ilk 4 bayt (huzme ID) kullanılır.
`LEN` beklenenden farklıysa log'a `MSG_UYARI HUZPAR len=…` yazılır, **cevap yine verilir** (veri ≥ 4 bayt ise).

**Cevap (`00000002`)**: `ID(4B) + LEN(4B) = 4·M + 8` + veri:

| Alan | Boyut | Değer |
|---|---|---|
| huzme ID | 4 B | istekteki huzme ID (aynen) |
| huzme başı zamanı (gclk) | 4 B | isteğin son beat'inde okunan serbest koşan `user_clk` sayacı (`uint32`) |
| ADK1 … ADK_M cevapları | 4 B × M | her biri huzme ID |

M=4: LEN=24, toplam 32 B = 8 beat. Her beat `tkeep=0xF`, son beat'te `tlast=1`. Değerler `uint32`, **little-endian**
(ID/LEN sayısal kelime olarak, ilk bayt `tdata[7:0]`).

**Parametreler:** `RESP_ENABLE` (1), `RESP_DELAY_CLKS` (125 = 1 µs), `M_ADK` (4), `N_CORE` (4), `F_EXTRA` (0),
`MAX_MSG_BYTES` (65536), `LOG_RAW_BEATS` (1; büyük mesajlarda 0 yaparak ham beat satırlarını kapatabilirsiniz),
`LOG_DATA_BYTES` (64; `MSG` satırına yazılan en fazla veri baytı).

**Log:** `MSG id=00000001 len=2872 data=78 56 34 12 … ... (toplam 2872 veri bayti)`, `HUZPAR_CEVAP planlandi …`,
`RX idx=… word=…`, `HUZPAR_CEVAP bitti`.

**Varsayımlar (doğrulanmadı):** gclk tanımı (gerçekte HB'de yakalanan bir sayaç olabilir); cevabın `tready` beklenmeden
verilmesi; BD'deki wrapper'da `iub_user_data_m_axis_rx_tready` girişi görünse de VIP'te `tready` portu yoktur.
**Açık soru:** 41 KB'lık HUZPAR isteği FPGA'ya PCIe'den nasıl geliyor (birden çok ardışık TLP mi)? Senaryo tarafı buna bağlı.

## Test

```bash
./test/run_verilator.sh      # Verilator >= 5.0 gerekir
```

| Test | Neyi doğrular |
|---|---|
| `tb/tb_cpu_check.sv` | Tek buffer (SIFPGA): birleşmiş/sahte kesme, sarma, bölünmüş yazma, pointer varyasyonları (11 mesaj) |
| `tb/tb_multi_check.sv` | **4 buffer**, MSI vektörüne göre yönlendirme (yalnız set bit okunur), RSI yok sayma, SHOB2 sarma, ayrı dosyalar |
| `tb/tb_cq_check.sv` | CPU→FPGA TLP baytları, tkeep/tuser, HB/bekleme zamanlaması, **BAR ID (`BAR2`, `bar5`, varsayılan BAR0)**, **otomatik bölme (300 B mesaj → 128+128+52 B paketler, başlık yalnız ilkte, BAR1, beat sayıları)** |
| `tb/tb_fill_check.sv` | Buffer doldurma / sarma / taşma tespiti |
| `tb/tb_aurora8b_check.sv` | Aurora 8b10b VIP: 125 MHz, link sırası, log, mesaj birleştirme, **HUZPAR cevabı** (720 beat istek → 1 µs sonra 8 beat cevap, huzme ID yansıtma, gclk, tlast/tkeep, diğer ID'lere cevap yok), reset kenarı |
| `tb/tb_aurora_check.sv` | Aurora VIP (+ **SHOB HUZPAR gözlemi**: 7744 bayt HO mesajı, Bypass, hatalı mesaj uyarıları, 480 satır katsayı, diğer ID'ler; + **CİT cevabı**: 0000E003 → 0000E004, 48 kelime, alan düzeni, 1 µs gecikme, tanımsız ID'ye cevap yok): 125 MHz, link sırası, UFC el sıkışması, RX boş, log içeriği, `reset_pb` ile yeniden link |

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
- `verification_v1.0.4/`: BAR ID, 4 buffer + MSI vektörü, ayrı dosyalar, Aurora gözlemci VIP.
- `verification_v1.0.5/`: v1.0.4 + SHOB CİT cevabı (0000E003 → 0000E004) + IÜB mesaj birleştirme ve HUZPAR cevabı (00000001 → 00000002).
- `verification_v1.0.7/` (bu klasör): v1.0.5 + SHOB hüzme verisi (00000002, 192 bit) + RSİ modeli + paylaşılan RSİ durumu + MSI7 + çok turlu senaryo üretici.
