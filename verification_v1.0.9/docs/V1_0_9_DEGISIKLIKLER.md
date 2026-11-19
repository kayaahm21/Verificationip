# v1.0.9 değişiklikleri (v1.0.8 temel alındı)

## Neden
100 turluk rastgele senaryo gerçek SİFPGA ile koşturulunca (RSİ tur özeti):
- SİFPGA bazı turları reddetti (NAK, hata kodu 03 = hatalı hüzme sayısı parametresi) ve RSİ'lere veri yazmadı.
- RSİ modeli MSI'ları **sırayla** turlara eşlediği için, bir tur hiç yazılmayınca sonraki her tur bir kayıyor ve
  doğru yazılmış veriler de "YANLIS" raporlanıyordu.

Log analizinden çıkan SİFPGA kabul sınırları (tasarımcıdan teyit edilmeli):

| Parametre | Kabul | Red |
|---|---|---|
| M (hüzme sayısı) | 4, 8, 12 | 16 |
| N = darbe × örnek | ≤ 64 | ≥ 80 (80, 84, 96 görüldü) |

RSİ başına hüzme dağılımı (n1/n2/n3) kural değil: `1/6/1`, `5/1/6`, `1/3/4` gibi dengesiz dağılımlar kabul edildi.

## Değişiklikler
1. **RSİ modeli turları hüzme ID'sine göre eşler** (`src/sim_model_rsi.sv`, `process_round`).
   - Gelen mesajın ID'si 2 ise header'daki hüzme ID'si okunur; RSİ'nin sırada beklediği turdan itibaren, bu ID'yi
     taşıyan ve bu RSİ'ye hüzme verilecek (`n_k > 0`) ilk tur seçilir.
   - Arada kalan turlar bu RSİ için **VERI GELMEDI** sayılır (`rsi_pkg::rsi_report_missing`). Sonraki turlar kaymaz.
   - ID bulunamazsa (ya da veri yoksa) eski davranış: sırada beklenen tur.
   - `rsiN_out.txt`'ye `ESLESME: huzme ID ile tur X secildi (sirada beklenen tur Y; ...)` satırı yazılır.
2. **`rsi_tur_ozeti.txt`**: veri gelmeyen turlar `| RSIk: VERI GELMEDI` ve
   `tur sonucu: VERI GELMEDI (SIFPGA turu reddetmis olabilir ...)` olarak yazılır.
   Simülasyon sonunda `report()` (ya da `rsi_pkg::rsi_flush_missing(k)`) çağrılırsa, hiç kapanmamış en sondaki turlar
   da aynı şekilde işaretlenir (`report()` otomatik çağrılmaz; son turlar reddedildiyse bu çağrı gerekir).
3. **`tools/gen_huzme_random.py`**: varsayılan `--m-max 12` ve yeni `--n-max 64` (N = darbe × örnek). 
   `examples/input_huzme_100_rastgele.txt` bu sınırlarla yeniden üretildi (M ∈ {4, 8, 12}, N ≤ 64, ≈ 11 MB).
4. `tb/tb_rsi_check.sv`: reddedilen tur (tur 6) + sonrasında normal tur (tur 7) ve `rsi_flush_missing` testleri.

## Notlar
- Sınırların nedenini (M ≤ 12, N ≤ 64) SİFPGA tasarımcısından öğrenin; `--m-max`, `--n-max` ile ayarlanabilir.
- `examples/input_huzme_nak_teshis.txt` (10 tur) sınırları ayrıca doğrulamak için duruyor.

## Tanılama eklentisi (RSİ modeli)
Gerçek SİFPGA koşusunda, reddedilen turların RSİ'ye yine yazdığı (bir önceki mesajın boyutunda) ve MSI'sız yazıların
sonraki tura sızdığı görüldü. Modelde bunu görünür kılmak için:
- `rsiN_out.txt`: `LEN uyusmuyor` yanında `TESHIS:` satırları (fazla/eksik bayt, "bir önceki turun boyutuyla aynı",
  1DEA0003'e göre beklenen toplam boyut) ve her turdan önce gelen MSI3 sayısı.
- `rsi_tur_ozeti.txt`: RSİ başına `LENFARK=<bayt>` (gelen bayt − (8+LEN)) ve `MSI3=<n>` (o turdan önce gelen MSI3 sayısı).
Davranış (DOGRU/YANLIS kararı) değişmedi; yalnızca teşhis bilgisi eklendi.
