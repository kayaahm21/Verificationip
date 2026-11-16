# RSİ modeli (`sim_model_rsi`)

RSİ = radar sinyal işleme işlemcisi. SİFPGA, hüzme verisini her RSİ'nin belleğine **PCIe MemWr** ile yazar. Gerçek RSİ'yi
bu modül taklit eder: veriyi alır, MSI ile haber verilince **çözer, doğrular, txt'ye döker, belleği siler.**
RSİ1, RSİ2, RSİ3 için **ayrı birer örnek** gerekir (`RSI_ID = 1, 2, 3`).

## Ne yapar?

1. **Bellek:** `s_axis_rq` üzerinden gelen her MemWr, seyrek (sparse) bellekte 4 baytlık kelimeler olarak tutulur.
   Dairesel değil, **pointer yok**, BAR yok. Her MSI1/MSI2'de dökülüp temizlenir (bellekte en çok bir tur kalır).
   Üst sınır `MAX_WORDS` (4 Mi kelime = 16 MiB); aşılırsa yazma atılır ve raporda görünür.
2. **Kesmeler (`cfg_interrupt_msi_int` bit'leri):**

   | Bit | Ad | Anlamı | Model ne yapar |
   |---|---|---|---|
   | 0 | MSI1 | SİFPGA→RSİ hüzme verileri **yazıldı** | turu kapatır (başarılı) |
   | 1 | MSI2 | SİFPGA→RSİ hüzme verileri **yazılamadı** | turu kapatır (başarısız olarak işaretler; yine de çözüp kontrol eder) |
   | 2 | MSI3 | SHOB→SİFPGA kanal verisi **eksik** | yalnızca log (bu sürümde hata enjeksiyonu yok) |
   | 3 | MSI4 | SHOB→SİFPGA kanal verisi **gelmedi** | yalnızca log |

3. **Mesaj formatı (ICD "SHOB HÜZME VERİSİ & SCİT", SİBFPGA → RSİ, ID `0x00000002`, little-endian):**

   | Bölüm | Bayt | İçerik |
   |---|---|---|
   | ID | 4 | `00000002` |
   | LEN | 4 | yalnızca veri (ID/LEN hariç) = `2072 + 8·K·N` |
   | HEADER | 88 | 0 hüzme ID (4), 4 durum (2), 6 alma hüzme sayısı (2), 8 darbe (4), 12 örnek (4), 16 reserved (8), 24..52 sekiz GAÇ kullanım maskesi, 56 SHOB-1 kart (1), 57 SHOB-2 kart (1), 58 reserved (30) |
   | Hüzme verisi | K·N·8 | **kanal başına: önce N adet I, sonra N adet Q** (`float32`); K kanal art arda |
   | GAÇ SCİT | 1920 | 240 GAÇ × 8 B |
   | SHOB SCİT | 32 | SHOB-1 (16) + SHOB-2 (16) |
   | SİBFPGA SCİT | 16 | |
   | FOOTER | 16 | `AAAAAAAA BBBBBBBB CCCCCCCC DDDDDDDD` (RSİ buffer'da hüzme verisinin bittiğini anlamak için) |

   Sabit kısım 2080 bayt; **K, gelen bayt sayısından hesaplanır**: `K = (bayt − 2080) / (8·N)`, `N = darbe × örnek` (header'dan).
   Örnek: RSİ1'e 2272 bayt indiyse `(2272 − 2080) / 64 = 3` kanal (N=8).

   *Eski sürümlerde model, kelimeleri başlıksız `I, Q, I, Q ...` çiftleri sanıyordu; bu yanlıştı (her çift `I[n], I[n+1]` olarak okunup hiçbiri
   `Q = −I` kontrolünü geçemiyordu).*

## Kontroller (her tur, her RSİ)

| Kontrol | Nasıl |
|---|---|
| **Adres** | En düşük yazılan adres = `RSİ başlangıç adresi (1DEA0001, index 96–119)` + `offset (1DEA0003)` |
| **Bitişiklik** | Kelimeler arasında boşluk yok |
| **ID ve LEN** | ID `0x00000002`; `8 + LEN` = gelen bayt sayısı |
| **Header** | huzme ID, darbe, örnek `1DEA0003` ile aynı; durum 0/1; alma hüzme sayısı M ya da bu RSİ'nin kanal sayısı; reserved ve GAÇ maskelerinin 30/31. bitleri sıfır (uyarı) |
| **Kanal sayısı** | `K` = `1DEA0003`'teki bu RSİ'ye indirilecek hüzme sayısı (bayt 36/37/38) |
| **Desen / birleştirme kuralı** | Her kanalın her örneği `±çarpan·kod` desenine uymalı, kanal içinde hüzme aynı ve örnek sırası 0..N−1. **Çarpan otomatik bulunur:** 3 = SHOB-1+SHOB-2 **toplamı** (beklenen), 1 = yalnız SHOB-1, 2 = yalnız SHOB-2 |
| **FOOTER** | Son 16 bayt `AAAAAAAA BBBBBBBB CCCCCCCC DDDDDDDD` ve mesajın sonunda |
| **SCİT'ler** | Yalnızca raporlanır (GAÇ SCİT'te sıfır olmayan kelime sayısı, SHOB/SİBFPGA SCİT değerleri) |
| **Birleşim (tüm RSİ'ler)** | Tur'un tüm RSİ'leri raporlayınca: 0..M−1 her hüzme **tam bir RSİ'de, tam bir kez** olmalı |

**Ham döküm:** Birleştirme kuralı ya da format bulunamasa bile dosyanın başında mesajın **ilk 32 kelimesi** adres, hex ve (tamsayı değerliyse) float
yorumuyla her zaman yazılır. Format uyuşmadığında ilk bakılacak yer burası.

Hüzmelerin hangi RSİ'ye gittiği **kontrol edilmez**, yalnızca raporlanır.

## Çıktı dosyaları

- `rsi_out_rsi<N>.txt` (`OUT_PREFIX` ya da `+RSI_OUT=`): tur başına ISR satırı, ham döküm, `MESAJ` (ID/LEN), `HEADER`, kanal sayısı, birleştirme kuralı,
  ilk `DETAIL_LINES` örnek (`kanal huzme ornek I Q`), hatalar, SCİT/FOOTER ve `TUR n SONUC: DOGRU/YANLIS`.
- `rsi_tur_ozeti.txt` (CPU paketi yazar): her tur için bir satır (RSİ başına `YAZILDI/YAZILAMADI`, huzme sayısı, `DOGRU/YANLIS`)
  ve tüm RSİ'ler bitince **birleşim** satırı (eksik/çift hüzme, kurallar).
- Konsol: `[RSIn] tur k: DOGRU/YANLIS, huzme=…, kural=…, hata=…`

## Tur eşleştirme (hangi MSI hangi tura ait?)

CPU VIP sürücüsü her `1DEA0003`'ü bir **tur** olarak sıraya koyar (`rsi_pkg` `t_*` dizileri). Her RSİ, kendi MSI1/MSI2'sinde sıradaki turu
kapatır (`rsi_tur_idx[RSI_ID]++`). Bu yüzden **`1DEA0003` o turun verisinden önce senaryoda yer almalı** ve her tur için her RSİ'den
bir MSI1/MSI2 gelmeli. Bir RSİ'ye hüzme düşmüyorsa (n_k = 0) o RSİ'den MSI beklenmez.

## Ortak durum (CPU VIP ↔ RSİ)

`1DEA0001` ve `1DEA0003` mesajları CPU VIP tarafından *sürülürken* `rsi_pkg::track_cfg_msgs` çağrılır (`VIP_RSI` tanımlıysa). Bu işlev:

- `1DEA0001`: veri index 96..119'dan **RSİ1/2/3 başlangıç adreslerini** okur (`rsi_start_addr[1:3]`),
- `1DEA0003`: offset'ler (0/8/16), hüzme ID (24), M (28), darbe (30), örnek (32), SHOB kullanımı (34), mod (35), RSİ başına hüzme sayısı
  (36/37/38) alanlarını okur ve **N = darbe×örnek** hesaplar.

Bölünen mesajlarda yalnızca **ilk TLP** ayrıştırılır (devam paketleri atlanır). `1DEA0001` 124 B veri olduğundan 33 DWORD'tür ve iki
TLP'ye bölünür; aranan alanlar ilk 120 baytın içinde olduğu için sorun olmaz.

> **Önemli:** RSİ modelini kullanan simülasyonda senaryoyu süren `sim_model_cpu` de bulunmalıdır; aksi halde adres/tur bilgisi
> hiç gelmez ve model yalnızca "ADRES kontrolü yapılamadı" uyarısıyla desen/kapsam kontrolleri yapar.

## Parametreler

| Parametre | Varsayılan | Anlamı |
|---|---|---|
| `RSI_ID` | 1 | 1..3 |
| `OUT_PREFIX` | `"rsi_out"` | çıktı öneki (`+RSI_OUT=` ile de verilebilir) |
| `ISR_LATENCY_NS` | 100 | MSI'dan sonra ISR gecikmesi |
| `MAX_WORDS` | 4194304 | bellekteki en çok 4 baytlık kelime |
| `DETAIL_LINES` | 64 | dosyaya yazılan örnek satırı (-1: hepsi, 0: yok) |

Top'a ekleme şablonu: `docs/sim_model_rsi_inst.vhd`.
