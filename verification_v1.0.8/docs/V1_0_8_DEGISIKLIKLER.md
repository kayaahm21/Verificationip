# v1.0.8 değişiklikleri (v1.0.7 temel alındı)

## Sorun
`input_huzme_MAX_tek_huzme.txt` gibi büyük hüzpar satırları (SHOB: 184376 bayt/satır) okunurken Vivado/xsim
belleği 32 GB'a dayandı ve bilgisayar kilitlendi. Bellek, `[GEN] Senaryo dosyasi okundu` satırı çıkmadan,
yani senaryo ayrıştırılırken doluyordu.

Neden: `scn_pkg::tokenize` her bayt için ayrı bir `string` üretip kuyruğa koyuyordu (satır başına yüz binlerce
string) ve `parse_line`/`parse_tlp` bu kuyruğu `ref` olmadan, değerle alıyordu.

## Çözüm (yalnızca `src/scn_pkg.sv`)
- `BIG_LINE_CHARS` (4096) karakterden uzun satırlar **akışlı** ayrıştırılır: ADRES, [BAR], MSGID ve LEN
  alanları string olarak, veri baytları doğrudan sayı olarak okunur ve LEN'e göre bir kez ayrılan `mbytes[]`
  dizisine yazılır. Token kuyruğu oluşmaz.
- Satır, yardımcı fonksiyonlara parametre olarak geçirilmez (her çağrıda kopyalanırdı); sınıf üyesi `bl`
  üzerinde çalışılır.
- Kısa satırlar (komutlar, `1DEA0001`, `1DEA0003` ...) eski yoldan geçer; davranış değişmedi.
- Aynı kurallar korunur: yorum (`#`, `//`), ayırıcılar, BAR alanı, LEN 4'ün katı, fazla/eksik/bozuk bayt
  uyarısı, otomatik bölme (32 DWORD).

## Doğrulama (Verilator)
v1.0.7 ve v1.0.8 ayrıştırıcıları aynı senaryolarda çalıştırılıp üretilen tüm paketler (bayt bayt) karşılaştırıldı:
orta boy çok turlu senaryo, `input_huzme_MAX_tek_huzme.txt` (3422 komut) ve hatalı büyük satırlar (fazla/eksik/
bozuk bayt, > 0xFF, geçersiz BAR, uzun yorum, komut + uzun yorum). Hepsinde paketler ve hata sayıları aynı.
Verilator xsim'in bellek davranışını taklit etmez; asıl bellek ölçümü Vivado'da yapılmalıdır.

## Dosyalar
`examples/input_huzme_MAX_tek_huzme.txt` v1.0.7'den kopyalanmıştır (M=96, N=32768, tek hüzme).
