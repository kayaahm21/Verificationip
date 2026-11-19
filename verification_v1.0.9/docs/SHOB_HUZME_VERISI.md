# SHOB hüzme verisi (`00000002`) göndericisi

`aurora_64b66b_vip` (SHOB-1 ve SHOB-2 için aynı modül) hüzme verisini SİFPGA'ya **`m_axi_rx_*`** (192 bit, `tready` yok)
üzerinden basar.

## Ne zaman gönderir? (HB'ye göre)

SHOB VIP, FPGA'dan gelen her **`0000E001` (HUZPAR ve KATSAYILAR)** mesajını çözüp bir **kuyruğa** (derinlik 8) koyar. Veri, HUZPAR'dan **sonra gelen
ilk hüzme başını (HB) bekleyerek** gönderilir; HB'den `DATA_DELAY_CLKS` (625 clk = 5 µs) sonra başlar.

**Kurallar:**

- **HUZPAR'dan önce olmuş HB sayılmaz.** Yalnızca HUZPAR çözüldükten sonraki HB'ler tetikler.
- **Bir HB tek mesaja yeter.** İkinci HUZPAR (kuyrukta) ikinci HB'yi bekler; mesajlar sırayla ve karışmadan gider.
- `darbe = 0` ya da `M = 0` olan HUZPAR için veri gönderilmez (`HUZME_VERI_ATLANDI`), HB beklenmeden hemen atlanır. Mesaj `DATA_MAX_BYTES` (32 MiB)
  sınırını aşıyorsa yine atlanır. Link (`channel_up`) kalkmadan veri gönderilmez.
- Çok turlu senaryoda tur *k*'nın HUZPAR'ı HB*k*'dan önce gelir, verisi HB*k*'dan sonra gider (gerçek akışla aynı). **Son turun verisi için son HB'den
  sonra simülasyonun biraz daha koşması gerekir** (HB + 5 µs + mesaj süresi).

### HB girişi (`huzme_basi`)

Gerçek Aurora IP'sinde HB girişi **yoktur**; bu giriş yalnızca VIP'e aittir. `PcieTop`/BD'de tasarımın HB hattına bağlanır (CPU VIP'in ürettiği HB ya da
gerçek HB). Darbenin pasiften aktife geçişi (kenar) algılanır, genişliği önemli değildir (1 clock yeter). `HB_ACTIVE_HIGH` ile polarite seçilir.

| `DATA_TRIGGER` | Davranış |
|---|---|
| **0 (varsayılan)** | `huzme_basi` bağlıysa (0/1 görüyorsa) HB'yi bekler; **bağlı değilse (Z)** eski davranış: HUZPAR + `DATA_DELAY_CLKS` |
| 1 | Her zaman HB'yi bekler. Bağlı değilse veri hiç gönderilmez |
| 2 | Her zaman HUZPAR + gecikme (v1.0.7'nin ilk hali), `huzme_basi` yok sayılır |

> **Dikkat:** `huzme_basi`'ya **sabit `'0'` bağlamayın**. Bağlı sayılır ve HB hiç gelmediği için veri hiç gönderilmez. HB'yi bağlamayacaksanız
> `DATA_TRIGGER => 2` verin. Verilator bağlanmayan girişi 0 sayar (xsim'de Z), bu yüzden Verilator testinde eski davranış `DATA_TRIGGER=2` ile seçilir.

**VHDL'de bağlantı örneği** (Aurora sarmalayıcısında ya da BD'de; sinyal adı sizin tasarımdaki HB hattı):

```vhdl
inst_aurora_shob_1 : entity xil_defaultlib.aurora_64b66b_vip
    -- GENERIC MAP (DATA_TRIGGER => 0, HB_ACTIVE_HIGH => 1)
    PORT MAP (
        ... mevcut portlar ...,
        huzme_basi => HuzmeBasi        -- SHOB-1 ve SHOB-2 örnekleri aynı HB'ye bağlanır
    );
```

> VHDL'den örneklerken yeni portu **mutlaka eşleyin**. Eşlenmeyen bir Verilog girişi xsim'de `formal port has no actual or default value`
> hatası verebilir. BD'de modül referansı yeniden paketlendiğinde yeni port görünür, HB hattına bağlayın.

**Log:** `aurora_huzme_<UNIT>.txt` içinde `HB_ALGILANDI`, `HUZME_VERI_BEKLIYOR` (HB modunda kuyruğa girince), `HUZME_VERI_BASLADI ... tetik=HB|HUZPAR`.

## Mesaj biçimi (192 bit AXI-S)

`ID(4) = 00000002`, `LEN(4)` (yalnızca veri), ardından veri. Hepsi **little-endian**; mesaj baytı `i`,
beat'in `tdata[8*(i%24) +: 8]` konumundadır. Beat'ler arka arkadır (`tvalid` kesintisiz), `tlast` son beat'te.

```
LEN  = 56 + M·N·8 + 960 + 16 + 16 = 1048 + 8·M·N
Toplam mesaj = 8 + LEN bayt; beat sayısı = ceil(toplam / 24)
```

Toplam 24'ün katı değilse **son beat kısmidir**: `tkeep`'in düşük bitleri 1, kalanı 0 (ör. M=4, N=8 → 1312 bayt =
54 tam beat + 16 baytlık son beat, `tkeep = 0x00FFFF`). Son olmayan beat'lerde `tkeep = 0xFFFFFF`.

| Bölüm | Boyut | İçerik |
|---|---|---|
| Başlık | 56 B | aşağıdaki tablo (ICD) |
| Örnekler | M·N·8 B | **örnek-ana**: `n = 0..N-1` için `m = 0..M-1` için `I (int32)`, `Q (int32)` |
| GAÇ SCİT | 960 B | sıfır |
| SHOB SCİT | 16 B | sıfır |
| Reserved | 16 B | sıfır |

**Başlık düzeni (ICD "SHOB-1 HÜZME VERİSİ & SCİT" tablosu; SHOB-2 için aynı):**

| Index | Boyut | Alan |
|---|---|---|
| 0 | 4 | Hüzme ID (HUZPAR'dakiyle aynı) |
| 4 | 2 | SHOB sinyal işleme durumu (0 Bypass, 1 HO) |
| 6 | 2 | SHOB alma hüzmesi sayısı M |
| 8 | 4 | Darbe sayısı |
| 12 | 4 | Darbedeki örnek sayısı |
| 16 | 8 | Reserved (sıfır) |
| 24 / 28 / 32 / 36 | 4 × 4 | GAÇ 1–30 / 31–60 / 61–90 / 91–120 kullanım durumu (HUZPAR'daki maskelerle aynı) |
| 40 | 1 | HI kullanım durumu: bit0 HI-1, bit1 HI-2, bit2 HI-3 (HUZPAR "kart kullanım durumu"nun bit1..3'ü) |
| 41 | 15 | Reserved (sıfır) |

> v1.0.7'nin ilk halinde 16–23'e N ve SHOB numarasını, 24–40'a sıfır yazıyordum; ICD tablosuna göre düzeltildi. GAÇ maskeleri sıfır
> gönderilirse alıcı "hiçbir GAÇ kullanılmıyor" diyebilirdi.

## Doğrulama deseni ("kendini tarif eden")

Her örnek kendi koordinatlarını taşır; böylece RSİ modeli, hiçbir ek bilgi olmadan yanlış yer/bozulma/eksik veriyi bulur:

```
kod = ((m + 1) << 15) | (n & 0x7FFF)        m = hüzme sırası (0 tabanlı), n = örnek sırası (0 tabanlı)
I = +çarpan · kod        Q = -çarpan · kod          (int32)
çarpan: shob_1 → 1, shob_2 → 2   (DATA_MUL = 0 iken UNIT_NAME'den; değilse elle)
```

Tüm değerler 2²⁴'ten küçüktür (M ≤ 96 → kod < 2²², ×2 < 2²³), yani **float32'ye dönüşüm tam**. SİFPGA iki SHOB'u
**toplarsa** RSİ'ye yazılan değer `3 · kod`'dur; yalnızca birini alırsa 1 ya da 2 · kod. RSİ modeli hangisi olduğunu
kendisi bulur ve raporlar (bkz. `RSI_MODELI.md`).

> Mesaj tek parça (CPI başına tek mesaj) varsayıldı; darbe başına ayrı mesaj gelirse N'in anlamı değişir.

## Parametreler (`aurora_64b66b_vip`)

| Parametre | Varsayılan | Anlamı |
|---|---|---|
| `DATA_ENABLE` | 1 | 0 → veri gönderme (v1.0.5 davranışı) |
| `DATA_DELAY_CLKS` | 625 | Tetikten (HB ya da HUZPAR) veri başlangıcına bekleme (user_clk, 125 MHz → 5 µs) |
| `DATA_TRIGGER` | 0 | 0 otomatik, 1 hep HB, 2 hep HUZPAR + gecikme (yukarıdaki tablo) |
| `HB_ACTIVE_HIGH` | 1 | `huzme_basi` polaritesi |
| `DATA_MUL` | 0 | desen çarpanı; 0 → `UNIT_NAME == "shob_2"` ise 2, yoksa 1 |
| `DATA_MAX_BYTES` | 33554432 | bundan büyük mesaj atlanır |

## Log

`aurora_huzme_<UNIT_NAME>.txt`: her mesaj için `HUZME_VERI_BASLADI huzme_id=… M=… darbe=… ornek=… N=… carpan=… mesaj_bayt=…
len=… beat=…` ve `HUZME_VERI_BITTI`; atlananlar için `HUZME_VERI_ATLANDI`, kuyruk taşması için `HUZME_VERI_UYARI`.
