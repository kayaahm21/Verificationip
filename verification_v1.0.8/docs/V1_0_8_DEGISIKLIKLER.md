# v1.0.8 değişiklikleri (v1.0.7 temel alındı)

## Sorun
`input_huzme_MAX_tek_huzme.txt` gibi büyük hüzpar satırları (SHOB: 184376 bayt/satır) okunurken Vivado/xsim
belleği 32 GB'a dayandı ve bilgisayar kilitlendi. Bellek, `[GEN] Senaryo dosyasi okundu` satırı çıkmadan,
yani senaryo ayrıştırılırken doluyordu.

Neden: `scn_pkg::tokenize` her bayt için ayrı bir `string` üretip kuyruğa koyuyordu (satır başına yüz binlerce
string) ve `parse_line`/`parse_tlp` bu kuyruğu `ref` olmadan, değerle alıyordu.

## Çözüm (yalnızca `src/scn_pkg.sv`)
İlk deneme (satırı `$fgets` ile alıp token kuyruğu olmadan taramak) xsim'de süreyi ve RAM'i düzeltmedi: Verilator'da
tepe bellek zaten ~26 MB idi, yani sorun algoritma değil, xsim'in 550 bin karakterlik tek bir string üzerindeki
`$fgets`/`getc`/`substr` davranışı. Bu yüzden:

- Dosya **`$fgetc` ile karakter karakter** okunur (`generator.stream_read = 1`, varsayılan). Büyük bir satır
  string'i hiç oluşmaz; yalnızca kısa token'lar (ADRES, BAR, MSGID, LEN, komutlar) string olur.
- TLP satırlarında veri baytları doğrudan sayı olarak okunup LEN'e göre bir kez ayrılan `mbytes[]` dizisine yazılır,
  sonra eskisi gibi 32 DWORD'luk paketlere bölünür.
- Komut satırları (`77777777`, `88888888`, `99999999`) ve hatalı ilk alanlar eski `parse_line` yolundan geçer.
- Eski yol korunur: `generator.stream_read = 0` ile `$fgets` + `tokenize` kullanılır.
- Aynı kurallar: yorum (`#`, `//`), ayırıcılar (boşluk, tab, virgül, CRLF), BAR alanı, LEN 4'ün katı,
  fazla/eksik/bozuk bayt uyarısı (hata metinleri biraz farklı olabilir), otomatik bölme, dosya sonunda satır sonu yok.

## Doğrulama (Verilator)
v1.0.7 ve v1.0.8 ayrıştırıcıları 20 farklı senaryo dosyasıyla çalıştırılıp üretilen tüm paketler/komutlar
bayt bayt karşılaştırıldı: tüm `examples/*.txt`, orta boy çok turlu senaryo, `input_huzme_MAX_tek_huzme.txt`
(3422 komut), CRLF/yorum/sonu yeni satırsız kenar durumlar ve hatalı satırlar. Hepsinde aynı; yalnızca
bitiş işaretinin satır numarası v1.0.8'de doğru (v1.0.7 Verilator'da 0 yazıyordu). Maksimum dosya 0,14 sn, ~12 MB.
Verilator xsim'in bellek davranışını taklit etmez; asıl ölçüm Vivado'da yapılmalıdır
(`test/xsim_bellek_teshis/`).

## Dosyalar
`examples/input_huzme_MAX_tek_huzme.txt` v1.0.7'den kopyalanmıştır (M=96, N=32768, tek hüzme).
