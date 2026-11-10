# SHOB hüzme verisi (`00000002`) göndericisi

`aurora_64b66b_vip` (SHOB-1 ve SHOB-2 için aynı modül) hüzme verisini SİFPGA'ya **`m_axi_rx_*`** (192 bit, `tready` yok)
üzerinden basar.

## Ne zaman gönderir?

SHOB VIP, FPGA'dan gelen her **`0000E001` (HUZPAR ve KATSAYILAR)** mesajını zaten çözüyordu. v1.0.7'de çözülen
her HUZPAR **bir kuyruğa** (derinlik 8) konur ve **`DATA_DELAY_CLKS` (625 clk = 5 µs) sonra** o hüzparın hüzme verisi gönderilir.

- HB, SHOB VIP'e verilmediği için tetik **HUZPAR + sabit gecikmedir** (gerçek sistemde HB'den sonra, post-CPI süresinde gider).
- Kuyruk sayesinde bir tur sürerken yeni HUZPAR gelirse (HB'ler arasında yeni hüzparlar gelir) mesajlar **sırayla** ve
  karışmadan gider; her mesaj kendi HUZPAR'ının parametreleriyle üretilir.
- `darbe = 0` ya da `M = 0` ise veri gönderilmez (`HUZME_VERI_ATLANDI`). Mesaj `DATA_MAX_BYTES` (32 MiB) sınırını
  aşıyorsa (ör. Bypass, M=960 ve büyük N) yine atlanır.
- Link (`channel_up`) kalkmadan veri gönderilmez.

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
| Başlık | 56 B | aşağıdaki tablo (**varsayım**) |
| Örnekler | M·N·8 B | **örnek-ana**: `n = 0..N-1` için `m = 0..M-1` için `I (int32)`, `Q (int32)` |
| GAÇ SCİT | 960 B | sıfır |
| SHOB SCİT | 16 B | sıfır |
| Reserved | 16 B | sıfır |

**Başlık düzeni (VARSAYIM - ICD'de ayrıntı yok, SİFPGA zaten kullanmıyorsa önemli değil):**

| Index | Boyut | Alan |
|---|---|---|
| 0 | 4 | huzme ID (HUZPAR'dakiyle aynı) |
| 4 | 2 | durum (HUZPAR'daki sinyal işleme durumu, HO = 1) |
| 6 | 2 | M (alma hüzme sayısı) |
| 8 | 4 | darbe sayısı |
| 12 | 4 | darbedeki örnek sayısı |
| 16 | 4 | N = darbe × örnek |
| 20 | 1 | SHOB no / desen çarpanı (shob_1 → 1, shob_2 → 2) |
| 21..55 | 35 | sıfır |

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
| `DATA_DELAY_CLKS` | 625 | HUZPAR'dan veri başlangıcına bekleme (user_clk, 125 MHz → 5 µs) |
| `DATA_MUL` | 0 | desen çarpanı; 0 → `UNIT_NAME == "shob_2"` ise 2, yoksa 1 |
| `DATA_MAX_BYTES` | 33554432 | bundan büyük mesaj atlanır |

## Log

`aurora_huzme_<UNIT_NAME>.txt`: her mesaj için `HUZME_VERI_BASLADI huzme_id=… M=… darbe=… ornek=… N=… carpan=… mesaj_bayt=…
len=… beat=…` ve `HUZME_VERI_BITTI`; atlananlar için `HUZME_VERI_ATLANDI`, kuyruk taşması için `HUZME_VERI_UYARI`.
