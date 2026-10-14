# Mimari - PCIe CQ VIP v1.0.2

Bu doküman VIP'in **ne yaptığını, nasıl çalıştığını ve kodun nasıl organize olduğunu** anlatır.
Hızlı kullanım için [README.md](README.md)'ye bakın.

---

## 1. Amaç ve kapsam

Gerçek sistemde bir **UltraScale+ PCIe IP**'si, host'tan (CPU) gelen bellek yazma isteklerini
**CQ (Completer Request)** AXI-Stream portundan tasarıma verir. Simülasyonda gerçek bir PCIe bağlantısı
olmadığı için bu IP'nin yerine `sim_model_cpu` adlı bir **VIP (Verification IP)** konur.

VIP şunları yapar:

| # | Görev |
|---|---|
| 1 | `user_clk` (125 MHz), `user_reset` (aktif yüksek) ve dahili link-up üretir |
| 2 | **Senaryo dosyasını** okur; TLP paketlerini `m_axis_cq_*` portundan tasarıma sürer |
| 3 | Senaryodaki **bekleme / huzme başı** komutlarını çalıştırır |
| 4 | `s_axis_rq_*` (tasarımın istekleri) için sadece `tready = 4'hF` verir |
| 5 | `cfg_interrupt_msi_*` isteklerine cevap verir (`msi_sent` darbesi) |
| 6 | Huzme başı (HB) sinyalini **izler** ve gerektiğinde **üretir** |

**Kapsam dışı:** gerçek PCIe IP'nin tüm `cfg_*` portları, RC/CC kanalları, PCIe fiziksel katmanı, RQ paketlerinin
çözülmesi ve completion üretilmesi. Bunlar bilinçli olarak yoktur.

---

## 2. Genel görünüm

```
                       senaryo dosyası (input_data.txt)
                                  │  satır satır
                                  ▼
                        ┌───────────────────┐
                        │     generator     │  (parser)  satır -> scn_cmd
                        └─────────┬─────────┘
                                  │ mailbox #(scn_cmd)
                                  ▼
 ┌─────────────────────────────────────────────────────────────────────────┐
 │                               driver                                    │
 │  CMD_TLP        ──▶ drive_item()  ──▶ axis_tx_if ──▶ m_axis_cq_*        │
 │  CMD_WAIT_NS    ──▶ #ns                                                 │
 │  CMD_WAIT_BEAM  ──▶ beam_ctrl.wait_beam()  ◀── huzme_basi_obs (giriş)   │
 │  CMD_PLAN_BEAM  ──▶ beam_ctrl.plan(ns) ──▶ huzme_basi_gen (çıkış)       │
 │  CMD_END        ──▶ "senaryo bitti" logu                                │
 └─────────────────────────────────────────────────────────────────────────┘

 sim_model_cpu (modül) bunların etrafında:
   user_clk / user_reset / link-up üretimi, RQ ready, MSI cevabı
```

Üç ana fikir vardır:

1. **Satır = komut.** Dosyadaki her satır bir `scn_cmd` nesnesine çevrilir.
2. **Komutlar sırayla yürütülür.** Bekleme komutları arkadan gelenleri bekletir; böylece senaryonun sırası korunur.
3. **Huzme başı iki ayrı portla yönetilir:** bir port **izler**, diğeri **üretir** (bkz. bölüm 7).

---

## 3. Dosyalar

| Dosya | Tür | İçerik |
|---|---|---|
| `src/axis_tx_if.sv` | interface | AXI-S arayüzü (`tvalid/tready/tdata/tkeep/tlast/tuser`) |
| `src/beam_if.sv` | interface | HB için `obs` (gözlenen), `gen` (üretilen), `clk` |
| `src/scn_pkg.sv` | package | `scn_cmd`, `tlp_item`, `generator`, `beam_ctrl`, `driver`, yardımcı fonksiyonlar |
| `src/sim_model_cpu.sv` | module | IP yerine geçen VIP; VHDL'den instantiate edilir |
| `tb/tb_system_top.vhd` / `.sv` | testbench | Tüm sistemi (Top) içeren üst seviye TB |
| `tb/tb_top.sv` | testbench | Sadece `design_1_wrapper` için bağımsız TB |
| `docs/sim_model_cpu_inst.vhd` | örnek | PcieTop.vhd için kısaltılmış instantiation |
| `examples/scenario_example.txt` | örnek | Her komuttan örnek içeren senaryo |

**Derleme sırası:** `axis_tx_if.sv` → `beam_if.sv` → `scn_pkg.sv` → `sim_model_cpu.sv`
(paket interface'lere, modül pakete bağlıdır).

---

## 4. Senaryo dosyası

### 4.1 Format

Her satır bir komuttur. Alanlar boşluk, tab veya virgülle ayrılır. `#` veya `//` işaretinden sonrası yorumdur.
Boş satırlar atlanır.

```
ADRES   MSGID  LEN  BYTE0 BYTE1 ...    TLP gönder
99999999                               huzme başını bekle
88888888  <ns>                         <ns> nanosaniye bekle
77777777  <ns>                         <ns> sonra huzme başı üret (bekletmez)
```

**Komutu belirleyen şey satırın ilk alanıdır** (TLP satırında burası adres alanıdır):

| İlk alan (hex) | Komut | Sonraki alanlar |
|---|---|---|
| `99999999` | `CMD_WAIT_BEAM` | yok |
| `88888888` | `CMD_WAIT_NS` | `<ns>` (onluk) |
| `77777777` | `CMD_PLAN_BEAM` | `<ns>` (onluk) |
| başka herhangi bir değer | `CMD_TLP` (adres) | `MSGID` (hex), `LEN` (onluk), `LEN` kadar bayt (hex) |

> **Dikkat:** Üç özel değer gerçek TLP adresi olarak **kullanılamaz**. Bir TLP'nin adresi tam olarak bunlardan
> biri olursa komut gibi yorumlanır.

### 4.2 TLP satırı alanları

| Alan | Biçim | Not |
|---|---|---|
| ADRES | hex, en fazla 16 hane | 64 bit bellek adresi, `0x` öneki ve `_` kabul edilir |
| MSGID | hex, en fazla 8 hane | 32 bit |
| LEN | onluk | Payload bayt sayısı. **4'ün katı** olmalı (padding yok) |
| BYTEn | hex, 1-2 hane | Tam olarak `LEN` tane olmalı |

### 4.3 Hata yönetimi

Hatalı satır **atlanır**, simülasyon durmaz. Satır numarasıyla `$error` basılır:

| Durum | Mesaj |
|---|---|
| İlk alan hex değil | `gecersiz ilk alan` |
| `88888888` / `77777777` sonrası sayı yok veya geçersiz | `komutun ardindan sure ... bekleniyor` |
| TLP satırı `ADRES MSGID LEN` biçiminde değil | `TLP satiri ... bicimde degil` |
| MSGID 32 bitten büyük / LEN çok büyük | `MSGID ... buyuk` |
| LEN 4'ün katı değil | `LEN ... 4'un kati degil` |
| Bayt sayısı ≠ LEN | `LEN=... ama ... veri bayti var` |
| Bayt geçersiz / 0xFF'ten büyük | `veri bayti ... gecersiz` |
| DWORD sayısı > 1024 | `$warning` (satır atlanmaz) |

---

## 5. Sınıflar ve sorumlulukları (`scn_pkg`)

### 5.1 `scn_cmd` ve `cmd_kind_e`

```
cmd_kind_e: CMD_TLP | CMD_WAIT_BEAM | CMD_WAIT_NS | CMD_PLAN_BEAM | CMD_END

scn_cmd { kind; tlp (sadece CMD_TLP); ns (CMD_WAIT_NS/PLAN_BEAM); line_no }
```
`generator` ile `driver` arasındaki **tek veri tipi** budur. Dosya sonunda `generator` bir `CMD_END` ekler.

### 5.2 `generator` (parser)

- `run()`: dosyayı `$fgets` ile satır satır okur. Her satırı `tokenize()` ile parçalar, `parse_line()`'a verir.
  Dosya bitince `CMD_END` ekler. Dosya bulunamazsa `$fatal`.
- `parse_line()`: ilk alanı `parse_hex()` ile 64 bit'e çevirir ve `case` ile komut türünü seçer.
- `parse_tlp()`: TLP'yi üretir (bölüm 6).

Yardımcı fonksiyonlar (paket seviyesinde):

| Fonksiyon | İş |
|---|---|
| `tokenize(line, toks)` | Boşluk/tab/virgülle böler, yorumu keser |
| `parse_hex(s, val)` | Hex metni 64 bit sayıya çevirir (`0x`, `_` kabul) |
| `parse_dec(s, val)` | Onluk metni 64 bit sayıya çevirir |

### 5.3 `driver`

Parametreleri: `DATA_WIDTH` (256), `TUSER_WIDTH` (88), `KEEP_GRAN` (4).

| Görev | İş |
|---|---|
| `reset()` | Çıkışları sıfırlar; `rst_n` (= `~user_reset & link_up`) 1 olana kadar bekler |
| `run()` | `forever`: mailbox'tan `scn_cmd` alır, türüne göre çalıştırır |
| `drive_item()` | Bir TLP'yi AXI-S beat'lerine bölüp sürer |
| `build_user()` | `tuser` değerini üretir |

`run()` içinde komutların yürütülmesi:

| Komut | Yapılan |
|---|---|
| `CMD_TLP` | `drive_item()` |
| `CMD_WAIT_NS` | `#(ns)` bekler, sonra bir sonraki clock kenarına hizalanır |
| `CMD_WAIT_BEAM` | `beam.wait_beam()` döner, sonra clock'a hizalanır |
| `CMD_PLAN_BEAM` | `beam.plan(ns)` - **bloklamaz**, sıradaki komuta hemen geçilir |
| `CMD_END` | `[SCN] Senaryo bitti` yazar. **`$finish` çağırmaz.** |

### 5.4 `beam_ctrl`

Bölüm 7'de ayrıntılı.

---

## 6. TLP yapısı ve AXI-S sürme

### 6.1 Paket (bayt dizilimi, little-endian)

| Bayt | Alan |
|---|---|
| 0-15 | **CQ descriptor** |
| 16-19 | `msg_id` |
| 20-23 | `data_len` (LEN) |
| 24… | payload |

Toplam boyut = `16 + 8 + LEN` bayt. `dword_count = (8 + LEN) / 4`.

### 6.2 CQ descriptor

| Alan | Değer |
|---|---|
| DW0-DW1 | Adres (`desc[0] = {addr[7:2], 2'b00}`, AT = 00; `desc[1..7] = addr[15:8] ... addr[63:56]`) |
| DW2 | `desc[8] = dword_count[7:0]`, `desc[9] = {1'b0, 4'b0001 (MemWr), dword_count[10:8]}` |
| `desc[10..15]` | **Şu an 0** (requester ID, tag, target function, BAR ID/aperture, TC, attr) |

### 6.3 Beat'lere bölme

256 bit = 32 bayt/beat. TLP beat'lere bölünür; her beat'te:

- `tdata`: ilgili 32 bayt, kalan kısım 0.
- `tkeep`: `KEEP_GRAN` baytlık gruplar için 1 bit. Gerçek IP'de `KEEP_GRAN = 4` → 8 bit (DWORD başına).
  `design_1_wrapper` test yolunda `KEEP_GRAN = 1` → 32 bit (bayt başına).
- `tlast`: son beat'te 1.
- `tvalid`: veri varken 1; `tready` 1 olmadan beat ilerlemez (**backpressure**). Sürücü bir sonraki clock kenarında
  `tready`'ye bakar, 1 ise beat'i kabul edilmiş sayar (`off += n_bytes`), değilse aynı beat'i tekrar sürer.

### 6.4 `tuser`

| `TUSER_WIDTH` | Düzen |
|---|---|
| `>= 88` (UltraScale+ CQ) | `first_be[3:0]`, `last_be[7:4]` ve `sop[40]` **ilk beat'te**; `byte_en[39:8]` payload baytları için 1 (descriptor baytları 0) |
| `< 88` (wrapper, 16 bit) | İlk beat'te `first_be[3:0]`, son beat'te `last_be[7:4]` |

> `byte_en` ve parity düzeni PG213'ten doğrulanmalıdır. Mevcut VHDL'de `m_axis_cq_tuser => open` olduğundan
> tasarımı şu an etkilemez.

---

## 7. Huzme başı (HB) yönetimi

### 7.1 Neden iki port?

Tasarımın içinde `HuzmeBasi` adlı tek bir tel vardır. İki ayrı iş vardır:

1. Birisi bu teli **sürmeli** (darbe vermeli).
2. VIP, `99999999` komutunu işlerken telde ne olduğunu **görmeli**.

Bir portun hem sürüp hem okuması çift sürücü karışıklığı yaratır, bu yüzden iki port ayrıldı:

| Port | Yön | Anlamı |
|---|---|---|
| `huzme_basi_obs` | giriş | Telde o an ne varsa. `wait_beam` bunu izler. |
| `huzme_basi_gen` | çıkış | VIP'in ürettiği darbe (sadece `SCRIPT` modunda). |

Bunlar `beam_if` içinde `obs` ve `gen` olarak durur ve `beam_ctrl` bu arayüzle çalışır.

### 7.2 `beam_ctrl`

| Metot | İş |
|---|---|
| `plan(ns)` | `SCRIPT` modunda `ns` sonra darbe üretmeyi **arka planda** başlatır (`fork ... join_none`). `DESIGN` modunda uyarı verip yok sayar. |
| `pulse()` | Clock kenarına hizalanır, `gen`'i aktif seviyeye çeker, `pulse_clks` clock tutar, bırakır |
| `wait_beam()` | `obs`'un **bir sonraki** aktif kenarını (`posedge`/`negedge`) bekler. Geçmiş darbeleri saymaz |

### 7.3 İki çalışma modu: "kim sürüyor?"

`SIM_MODE` (VIP'i açıp kapatan generic) ile karıştırılmamalıdır. Buradaki ayrım, **HB telini kimin sürdüğüdür**:

| | `BEAM_SOURCE = "SCRIPT"` (şimdi) | `BEAM_SOURCE = "DESIGN"` (gerçek modül bağlanınca) |
|---|---|---|
| HB'yi kim üretir | VIP (`77777777`) | Tasarımdaki gerçek modül |
| VHDL | `HuzmeBasi <= huzme_basi_gen_sig;` | atama silinir, `huzme_basi_gen => open` |
| `77777777` | `ns` sonra `gen`'de darbe | uyarı verilip yok sayılır |
| `99999999` | `obs`'u bekler (kendi darbesini görür) | `obs`'u bekler (gerçek darbeyi görür) |

Geçişte VIP kodu **değişmez**; yalnızca VHDL'deki atama kalkar ve `BEAM_SOURCE` değişir
(`+BEAM_SOURCE=DESIGN` ile derlemeden de seçilebilir).

```
SCRIPT modu:                              DESIGN modu:
 77777777 ─▶ beam_ctrl ─▶ huzme_basi_gen   gerçek modül ─▶ HuzmeBasi
                              │                              │
              HuzmeBasi <= ───┘                              ▼
                  │                                    huzme_basi_obs
                  ▼                                          ▲
            huzme_basi_obs ◀── 99999999 bekler               └── 99999999 bekler
```

### 7.4 Zamanlama örneği (Verilator ile doğrulanan davranış)

`examples/scenario_example.txt`'in ilk satırları (HB geri beslemesi bir clock gecikmeli test düzeneğiyle):

```
[0 ns]    PLAN_BEAM 1000
[0 ns]    WAIT_BEAM basladi
[1004 ns] [BEAM] HB darbesi basladi        <- 1000 ns + clock kenarina hizalama
[1012 ns] WAIT_BEAM bitti
[1020 ns] TLP  ...                          <- bekleme bitince mesajlar gonderilir
[1020 ns] WAIT_NS 500
[1524 ns] TLP  ...                          <- 500 ns + hizalama
```

---

## 8. `sim_model_cpu` modülü

### 8.1 Portlar

| Port | Yön | Açıklama |
|---|---|---|
| `sys_clk` | in | Dışarıdan gelir; VIP içinde kullanılmıyor |
| `user_clk` | out | 125 MHz (8 ns periyot) |
| `user_reset` | out | Aktif yüksek; başlangıçta 20 clock reset |
| `m_axis_cq_tdata[255:0]`, `tkeep[7:0]`, `tlast`, `tuser[87:0]`, `tvalid` | out | CQ: VIP → tasarım |
| `m_axis_cq_tready` | in | Tasarımdan |
| `s_axis_rq_tdata[255:0]`, `tkeep[7:0]`, `tlast`, `tuser[61:0]`, `tvalid` | in | RQ: tasarım → VIP (kullanılmıyor) |
| `s_axis_rq_tready[3:0]` | out | Her zaman `4'hF` |
| `cfg_interrupt_msi_int[31:0]` | in | MSI isteği |
| `cfg_interrupt_msi_sent` | out | `msi_int != 0` ise 2 clock sonra 1 |
| `cfg_interrupt_msi_fail` | out | 0'a sabit |
| `huzme_basi_obs` | in | Tasarımdaki HB teli (izlenir) |
| `huzme_basi_gen` | out | VIP'in ürettiği HB |

Port adları **küçük harflidir**: VHDL çağırırken büyük/küçük harf karışıklığı çıkmasın diye.

### 8.2 Parametreler

| Parametre | Varsayılan | Açıklama |
|---|---|---|
| `INPUT_FILE` | `"input_data.txt"` | Senaryo dosyası (`+TLP_FILE=` ile ezilir) |
| `CQ_KEEP_WIDTH` / `RQ_KEEP_WIDTH` | 8 / 8 | `tkeep` genişliği. `KEEP_GRAN = 32 / CQ_KEEP_WIDTH` olarak türetilir |
| `BEAM_SOURCE` | `"SCRIPT"` | `"SCRIPT"` veya `"DESIGN"` (`+BEAM_SOURCE=` ile ezilir) |
| `BEAM_PULSE_CLKS` | 1 | Üretilen HB darbesinin genişliği |
| `BEAM_ACTIVE_HIGH` | 1 | HB aktif seviyesi |

### 8.3 Başlangıç sekansı

```
t = 0           user_reset = 1, link_up = 0
+20 clock       user_reset = 0
+20 clock       link_up = 1            -> driver.reset() döner
sonra           driver.run() arka planda başlar, generator.run() dosyayı okur
```
`axis_tx_if`'in `rst_n` girişi `~user_reset & link_up`'tır; böylece driver link yukarı çıkmadan TLP sürmez.

### 8.4 Diğer davranışlar

- **RQ:** Sadece `s_axis_rq_tready = 4'hF`. Gelen paketler çözülmez.
- **MSI:** `|cfg_interrupt_msi_int` 1 olunca iki clock sonra `cfg_interrupt_msi_sent` bir clock 1 olur
  (tasarımın MSI beklerken kilitlenmesini önler). `cfg_interrupt_msi_fail` hep 0.

---

## 9. VHDL ile entegrasyon

Ayrıntılı örnek: `docs/sim_model_cpu_inst.vhd`.

1. Dosyaları **simulation source** olarak, tip `SystemVerilog`, kütüphane `xil_defaultlib` ile ekle.
2. VHDL'deki instantiation `entity xil_defaultlib.sim_model_cpu` ile yapılır.
3. **Karma dil sınırı:** SV portlarına yalnızca `std_logic` / `std_logic_vector` bağlanabilir. Özel dizi tipleri veya
   record alanları için VHDL'de standart tipli ara sinyal kullanıp atamayı VHDL tarafında yapın.
4. `HuzmeBasi`, `PcieTop`'un **giriş portuysa** `HuzmeBasi <= huzme_basi_gen_sig;` ataması orada yapılamaz;
   HB'nin üretildiği üst seviyede yapılmalıdır.
5. Gerçek IP dalı (`SIM_MODE = FALSE`) ile VIP dalı birbirini dışlamalıdır; aksi hâlde çift sürücü olur.

---

## 10. Yeni komut eklemek

1. `scn_pkg.sv`'de yeni bir özel adres sabiti (`ADDR_...`) ve `cmd_kind_e`'ye yeni değer ekle.
2. `generator.parse_line()` içindeki `case`'e yeni dalı ekle (alanları ayrıştır, `scn_cmd` doldur).
3. `driver.run()` içindeki `case`'e yeni komutun yürütmesini ekle.
4. `examples/` ve bu dokümana yaz.

---

## 11. Bilinen sınırlar ve yapılacaklar

- CQ descriptor'daki requester ID / tag / BAR / TC / attr alanları **0**.
- Büyük yazmalar MPS ve 4 KB sınırına göre **bölünmez**.
- `tuser` `byte_en` ve parity düzeni PG213 ile doğrulanmalı.
- `99999999` için **zaman aşımı yoktur**; HB hiç gelmezse senaryo orada bekler (simülasyon süresini TB sınırlar).
- RQ tarafı sadece sink; completion üretilmez.
- `sys_clk` kullanılmıyor.
- Üç özel adres değeri gerçek TLP adresi olarak kullanılamaz.

## 12. Test durumu

- **Doğrulandı (Verilator 5.020, mini TB):** satır ayrıştırma, yorum/boş satır atlama, 4 hatalı satır türünün
  yakalanması, `88888888` beklemesi, `77777777` planlaması (arka plan darbesi), `99999999` beklemesi, descriptor baytları.
- **Doğrulanmadı:** `driver.drive_item()` AXI-S sürmesi, `sim_model_cpu` modülü, VHDL entegrasyonu ve
  `tb_system_top`. Ortamda Vivado/xsim yok; Verilator "virtual interface never assigned" kısıtı nedeniyle `driver`
  sınıfını kabul etmedi. İlk Vivado derlemesinde küçük hatalar çıkabilir.
