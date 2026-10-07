# PCIe CQ VIP (UltraScale+ IP yerine simülasyon modeli)

Radar sistemi doğrulaması için, gerçek **Xilinx UltraScale+ PCIe IP**'sinin yerine konan
SystemVerilog tabanlı bir VIP (Verification IP). VIP, bir metin dosyasındaki mesajları
**TLP (Memory Write)** paketlerine çevirir ve IP'nin **CQ (Completer Request)** AXI-Stream
portundan tasarıma sürer. Tasarımın **RQ** (Requester Request) çıkışını ise şimdilik sadece
"ready" vererek karşılar.

> Durum: kod henüz bir simülatörde derlenmedi/koşturulmadı. Vivado xsim ile ilk derlemede çıkan
> hataları düzeltmek gerekebilir.

---

## 1. Genel mimari

```
 input_data.txt
      │  (adres, msg_id, uzunluk, payload baytları)
      ▼
 ┌───────────┐  mailbox  ┌──────────┐  axis_tx_if   ┌──────────────────────┐
 │ generator │──────────▶│  driver  │──────────────▶│ m_axis_cq_*  (VIP→DUT)│
 └───────────┘ (tlp_item)└──────────┘               │                      │
                                                    │ sim_model_cpu.sv     │
   user_clk 125 MHz, user_reset, lnk_up, MSI cevabı │                      │
                                                    │ s_axis_rq_*  (DUT→VIP)│ tready = 1
                                                    └──────────────────────┘
```

İki kullanım şekli var:

| Kullanım | Dosya | Amaç |
|---|---|---|
| **Bağımsız TB** | `tb/tb_top.sv` | VIP'i `design_1_wrapper` (kısaltılmış test yolu) üzerinde denemek |
| **Ana sistem içinde** | `src/sim_model_cpu.sv` | VHDL'deki `sim_model_cpu` entity'sinin yerine geçmek |

## 2. Dosyalar

| Dosya | İçerik |
|---|---|
| `src/axis_tx_if.sv` | AXI-Stream interface'i (`tvalid/tready/tdata/tkeep/tlast/tuser`). Parametreler: `DATA_WIDTH`, `TUSER_WIDTH`, `KEEP_GRAN`. |
| `src/cq_vip_pkg.sv` | `tlp_item`, `generator`, `driver` sınıfları. |
| `src/sim_model_cpu.sv` | IP yerine geçen modül: clock/reset/link üretimi, CQ sürme, RQ sink, MSI cevabı. |
| `tb/tb_top.sv` | `design_1_wrapper` için bağımsız testbench. |
| `docs/sim_model_cpu_inst.vhd` | VHDL'de kullanılacak kısaltılmış instantiation. |

**Derleme sırası:** `axis_tx_if.sv` → `cq_vip_pkg.sv` → `sim_model_cpu.sv` (veya `tb_top.sv`).
Ana sistemde bu dosyalar `xil_defaultlib` kütüphanesine, **SystemVerilog** tipinde eklenmelidir.

## 3. Giriş dosyası formatı

Her mesaj bir satır başlığı + payload baytlarından oluşur (boşlukla ayrılmış):

```
<adres_hex> <msg_id_hex> <data_len_dec> <byte0_hex> <byte1_hex> ... <byte(data_len-1)_hex>
```

Örnek:

```
0000000012345600 0000000A 8 11 22 33 44 55 66 77 88
```

- `data_len` **4'ün katı** olmalıdır (padding yoktur). Değilse generator `$error` verir, mesajı atlar.
- Dosya yolu: `sim_model_cpu` parametresi `INPUT_FILE` veya simülasyon argümanı `+TLP_FILE=<dosya>`.
  `tb_top`'ta `gen = new(mbx, "input_data.txt")`.

## 4. Paket (TLP) yapısı

Generator her mesaj için aşağıdaki bayt dizisini üretir (little-endian):

| Bayt aralığı | Alan |
|---|---|
| 0–15 | **CQ descriptor** (16 bayt) |
| 16–19 | `msg_id` (4 bayt) |
| 20–23 | `data_len` (4 bayt) |
| 24… | payload (`data_len` bayt) |

Toplam TLP boyutu = `16 + 8 + data_len` bayt. Descriptor içinde `DWORD count = (8 + data_len)/4`.

Descriptor alanları:

- DW0–DW1: bellek adresi (`desc[0] = {addr[7:2], 2'b00}`, AT=00; üst baytlar `addr[63:8]`).
- DW2: `desc[8] = dword_count[7:0]`, `desc[9] = {0, 4'b0001 (MemWr), dword_count[10:8]}`.
- `desc[10..15]` (requester ID, tag, target function, BAR ID/aperture, TC, attr) **şu an 0**.

`tlp_item` ayrıca `first_be` / `last_be` taşır (padding olmadığından ikisi de `4'b1111`).

## 5. Driver nasıl çalışır?

1. `reset()` — çıkışları sıfırlar, `vif.rst_n === 1` olana kadar bekler.
   `sim_model_cpu` içinde `rst_n = ~user_reset & user_lnk_up` olduğundan driver, **link yukarı çıkana kadar başlamaz**.
2. `run()` — mailbox'tan `tlp_item` alır, `drive_item()` çağırır.
3. `drive_item()` — TLP'yi `DATA_WIDTH/8` baytlık beat'lere böler:
   - her beat'te `tdata`, `tkeep`, `tlast`, `tuser` sürülür;
   - bir sonraki clock kenarında `tready === 1` ise beat kabul edilmiş sayılır ve ilerlenir, değilse aynı beat tutulur (backpressure);
   - paket bitince `tvalid` düşer.

### `tkeep` ve `KEEP_GRAN`
`KEEP_GRAN`, bir `tkeep` bitinin kaç bayta karşılık geldiğidir.
- Gerçek IP (256-bit, **tkeep = 8 bit**): `KEEP_GRAN = 4` (DWORD başına).
- Wrapper test yolu (**tkeep = 32 bit**): `KEEP_GRAN = 1` (bayt başına).

### `tuser`
- `TUSER_WIDTH >= 88` → **UltraScale+ CQ düzeni**: ilk beat'te `first_be[3:0]`, `last_be[7:4]`, `sop[40]`;
  `byte_en[39:8]` payload baytları için set edilir (descriptor baytları hariç).
  *`byte_en` ve parity düzeni PG213'ten doğrulanmalıdır (kodda TODO).*
- `TUSER_WIDTH < 88` (wrapper, 16 bit) → basit düzen: ilk beat'te `first_be`, son beat'te `last_be`.

## 6. `sim_model_cpu` modülü

### Portlar

| Port | Yön | Açıklama |
|---|---|---|
| `sys_clk` | in | Dışarıdan gelir; VIP içinde kullanılmıyor |
| `user_clk` | out | 125 MHz (8 ns periyot) |
| `user_reset` | out | Aktif yüksek; başlangıçta 20 clock reset |
| `user_lnk_up`, `phy_rdy_out` | out | Reset'ten 20 clock sonra 1 |
| `cfg_local_error_out[4:0]` | out | 0'a sabit |
| `m_axis_cq_tdata[255:0]`, `tkeep[7:0]`, `tlast`, `tuser[87:0]`, `tvalid` | out | CQ: VIP → tasarım |
| `m_axis_cq_tready` | in | Tasarımdan |
| `s_axis_rq_tdata[255:0]`, `tkeep[7:0]`, `tlast`, `tuser[61:0]`, `tvalid` | in | RQ: tasarım → VIP |
| `s_axis_rq_tready` | out | Her zaman 1 |
| `cfg_interrupt_msi_int[31:0]` | in | MSI isteği |
| `cfg_interrupt_msi_sent` | out | `msi_int` sıfırdan farklıysa 2 clock sonra 1 |
| `cfg_interrupt_msi_fail` | out | 0'a sabit |

Parametreler: `INPUT_FILE`, `CQ_KEEP_WIDTH` (8), `RQ_KEEP_WIDTH` (8).

Gerçek IP'nin diğer tüm portları (`pci_exp_*`, `cfg_*` çoğu, `m_axis_rc_*`, `s_axis_cc_*`, `pcie_rq_*`, …)
**bilinçli olarak kaldırılmıştır**; VHDL instantiation'ı buna göre kısaltılmıştır.

### Başlangıç sekansı
```
t=0            user_reset=1, link_up=0
+20 clock      user_reset=0
+20 clock      user_lnk_up=1, phy_rdy_out=1  → driver.reset() döner
sonra          driver.run() arka planda başlar, generator.run() dosyayı okuyup mailbox'a koyar
```

## 7. Ana sisteme entegrasyon (VHDL)

1. Dosyaları `xil_defaultlib`'e SystemVerilog olarak ekle (sıra: bölüm 2).
2. VHDL'deki yorum satırlı `gen_sim_model_cpu` bloğunu `docs/sim_model_cpu_inst.vhd` ile değiştir.
3. `clk_user_cpu_pcie`, `rst_user_cpu_pcie` ve `cdc_lnk_up_cpu_pcie` sinyallerinin başka bir yerden sürülmediğini kontrol et
   (artık VIP sürüyor).
4. `buf_cpu_m_axis_cq_tkeep` ve `buf_cpu_s_axis_rq_tkeep` genişliği 8 bit olmalı.
5. Veri dosyası için `+TLP_FILE=...` veya `INPUT_FILE` kullan; dosya simülasyon çalışma dizininde olmalı.

> VHDL'den SV modülü instantiate edilirken üst seviye portlarda yalnızca basit `logic` vektörleri kullanılmıştır
> (interface/struct yok); bu Vivado karma-dil simülasyonu için gereklidir.

## 8. Bağımsız testbench (`tb/tb_top.sv`)

`design_1_wrapper`'ın `S_AXIS_0` portuna (256-bit, tkeep 32, tuser 16) paket sürer;
çıkış `tready`'leri 1'e çekilir (HLS IP'lerin kilitlenmemesi için).
Akış: clock (250 MHz) → reset → `drv.reset()` → `drv.run()` → `gen.run()` → 5 µs bekle → `$finish`.

## 9. Bilinen sınırlar / yapılacaklar

- CQ descriptor'daki requester ID / tag / BAR / TC / attr alanları 0.
- Generator büyük yazmaları `MPS` ve 4 KB sınırına göre bölmüyor (DWORD count en fazla 1024).
- `tuser` `byte_en` ve parity düzeni PG213 ile doğrulanmalı.
- RQ tarafı sadece sink; paketler decode edilmiyor, completion üretilmiyor.
- `sys_clk` kullanılmıyor.
- Kod gerçek bir simülatörde derlenip koşturulmadı.
