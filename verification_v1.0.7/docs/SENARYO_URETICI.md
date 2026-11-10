# Çok turlu senaryo üretici (`tools/gen_huzme_rounds.py`)

Adres atama + her tur için SİFPGA/SHOB-1/SHOB-2/IÜB hüzparlarını ve HB zamanlamasını içeren **tek senaryo dosyası** üretir.

```bash
python3 tools/gen_huzme_rounds.py > examples/input_huzme_turlari.txt                       # 3 varsayılan tur
python3 tools/gen_huzme_rounds.py --round 8,2,4 --round 12,1,8,4,4,4 --period-ns 60000 > x.txt
python3 tools/gen_huzme_rounds.py --offset-mode step --offset-step 0x1000 --round 4,1,4 --round 4,1,4 > y.txt
```

## Tur parametresi: `--round M,DARBE,ORNEK[,n1,n2,n3]`

- `M`: alma hüzme sayısı (HO: 4..96, 4'ün katı), `DARBE` > 0, `ORNEK` > 0 ve 4'ün katı. **N = DARBE × ORNEK.**
- `n1,n2,n3`: RSİ'lere indirilecek hüzme sayıları (toplamı `M`). Verilmezse `M`, 3'e eşite yakın bölünür, artan RSİ1'den başlayarak
  dağıtılır (ör. M=8 → 3/3/2; M=4 → 2/1/1; M=12 → 4/4/4).
- `--round` tekrarlanabilir (her biri bir tur). Hiç verilmezse `8,2,4`, `4,1,4`, `12,2,4`.

## Dosyanın yapısı

```
1DEA0001  (BAR0, 124 B)   4 buffer + RSİ1/2/3 başlangıç adresleri (index 96..119) + RSİ sayısı + kesme aralığı
88888888 2000             2 µs bekle
-- her tur için --
77777777 <period_ns>      bu turun HB'sini planla
1DEA0003  (BAR0, 56 B)    RSİ offset'leri, hüzme ID, M, darbe, örnek, RSİ başına hüzme sayısı
0000E001  (BAR1)          SHOB-1 HUZPAR (HO + katsayılar)  → SHOB-1 VIP DATA_DELAY sonra hüzme verisini basar
0000E001  (BAR2)          SHOB-2 HUZPAR
00000001  (BAR3)          IÜB HUZPAR  → IÜB VIP cevabı
99999999                  HB gelene kadar bekle (tur süresi)
```

Hüzme ID turdan tura 1 artar (`--huzme-id`, varsayılan `0xA001`). Büyük mesajlar (> 32 DWORD) VIP tarafından otomatik
32 DWORD'luk TLP'lere bölünür.

## Önemli ayarlar

| Seçenek | Varsayılan | Anlamı |
|---|---|---|
| `--period-ns` | 60000 | Tur süresi. SHOB verisi (5 µs gecikme + beat sayısı×8 ns) ve RSİ yazımı **bu sürede bitmeli**; bitmezse tasarımın "yazılamadı" (MSI2) yolu tetiklenir |
| `--rsi-start` | `0x10000000,0x20000000,0x30000000` | RSİ başlangıç adresleri (1DEA0001, 96..119) |
| `--offsets` | `0,0,0` | ilk tur RSİ offset'leri (4'ün katı) |
| `--offset-mode` | `fixed` | `step`: her tur `--offset-step` kadar kayar (offset'in turdan tura değişebildiği durumu dener) |
| `--irq-interval-us` | 16 | `1DEA0001` index 121 |
| `--iub-m`, `--iub-n` | 4, 4 | IÜB HUZPAR boyutu |

Katsayılar ve IÜB verisi rastgele (sabit tohum `--seed`); SHOB hüzme verisi bunlara bağlı değildir.

## Gerçek sisteme göre sapmalar (bilinçli)

Gerçekte hüzparlar bir **önceki** turun HB'si ile yeni HB arasında gelir ve veri HB'den *sonra* basılır; bu VIP'te SHOB'a HB verilmediği
için veri **HUZPAR + 5 µs**'de başlar. Senaryoda HB komutları (`77777777`/`99999999`) yalnızca tur zamanlaması içindir.
