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

3. **Veri formatı:** `float32` I, sonra `float32` Q (8 bayt/örnek). Bu, RSİ modelinin işlemci taklidi olması ve
   verinin float yazılması gerektiğinden (toplantı kararı) seçildi. **int32→float dönüşümünün tam biçimi bilinmiyor**; model,
   değerlerin tamsayı değerli olmasını bekler (düz çevrim). Ölçekleme varsa "HATALI örnek" satırlarında ham değerler görünür.

## Kontroller (her tur, her RSİ)

| Kontrol | Nasıl |
|---|---|
| **Adres** | En düşük yazılan adres = `RSİ başlangıç adresi (1DEA0001, index 96–119)` + `offset (1DEA0003, 0/8/16)` |
| **Bitişiklik** | Kelimeler arasında boşluk yok, kelime sayısı çift (I/Q çiftleri tam) |
| **Desen / birleştirme kuralı** | Her I/Q çifti `±çarpan·kod` desenine uymalı. **Çarpan otomatik bulunur:** 3 = SHOB-1+SHOB-2 **toplamı** (beklenen), 1 = yalnız SHOB-1, 2 = yalnız SHOB-2. Kural dosyaya yazılır; 3 dışı çıkarsa uyarı |
| **Yerleşim** | Huzme-ana (`m→n`) mı, örnek-ana (`n→m`) mı otomatik saptanır ve raporlanır |
| **Eksiksizlik** | Her hüzmede tam **N = darbe×örnek** örnek, her `(m, n)` bir kez; m < M |
| **Hüzme sayısı** | RSİ'ye düşen hüzme sayısı = `1DEA0003`'teki o RSİ'nin "indirilecek kanal sayısı" (bayt 36/37/38) |
| **Birleşim (tüm RSİ'ler)** | Tur'un tüm RSİ'leri raporlayınca: 0..M-1 her hüzme **tam bir RSİ'de, tam bir kez** olmalı |

Hüzmelerin hangi RSİ'ye gittiği **kontrol edilmez**, yalnızca raporlanır (kural toplantıda doğrulanmadı; "bloklar halinde,
fazlalık RSİ1'e" varsayıldı, yalnızca sayı kontrolü yapılır).

## Çıktı dosyaları

- `rsi_out_rsi<N>.txt` (`OUT_PREFIX` ya da `+RSI_OUT=`): tur başına ISR satırı, adres/kural/yerleşim/kapsam sonuçları, ilk
  `DETAIL_LINES` örnek (`adres huzme ornek I Q`), hatalar ve `TUR n SONUC: DOGRU/YANLIS`.
- `rsi_tur_ozeti.txt` (CPU paketi yazar): her tur için bir satır (RSİ başına `YAZILDI/YAZILAMADI`, huzme sayısı, `DOGRU/YANLIS`)
  ve tüm RSİ'ler bitince **birleşim** satırı (eksik/çift hüzme, kurallar).
- Konsol: `[RSIn] tur k: DOGRU/YANLIS, huzme=…, kural=…, hata=…`

## Tur eşleştirme (hangi MSI hangi tura ait?)

CPU VIP sürücüsü her `1DEA0003`'ü bir **tur** olarak sıraya koyar (`cpu_pkg::turlar`). Her RSİ, kendi MSI1/MSI2'sinde sıradaki turu
kapatır (`rsi_tur_idx[RSI_ID]++`). Bu yüzden **`1DEA0003` o turun verisinden önce senaryoda yer almalı** ve her tur için her RSİ'den
bir MSI1/MSI2 gelmeli. Bir RSİ'ye hüzme düşmüyorsa (n_k = 0) o RSİ'den MSI beklenmez.

## Ortak durum (CPU VIP ↔ RSİ)

`1DEA0001` ve `1DEA0003` mesajları CPU VIP tarafından *sürülürken* `cpu_pkg::track_cfg_msgs` çağrılır. Bu işlev:

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
