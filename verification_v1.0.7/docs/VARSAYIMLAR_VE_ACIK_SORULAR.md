# Varsayımlar ve açık sorular (v1.0.7)

ICD'de olmayan ya da doğrulanmamış her şey burada. **Kod bu varsayımlarla çalışır**; yanlış çıkanı düzeltmek için ilgili yer verildi.

## Varsayımlar

| # | Konu | Varsayım | Yanlışsa nerede değişir |
|---|---|---|---|
| V1 | Hüzme verisi mesajı | ID `00000002`, `LEN = 56 + M·N·8 + 960 + 16 + 16`, CPI başına **tek mesaj** | `aurora_64b66b_vip.v` (gönderici bölümü) |
| V2 | Başlık düzeni (56 B) | **ICD tablosuyla doğrulandı** (huzme ID, durum, M, darbe, örnek, reserved, 4 GAÇ maskesi, HI kullanım); GAÇ/HI değerleri HUZPAR'dan kopyalanır | `d_byte` fonksiyonu |
| V3 | Örnek sırası | örnek-ana (`n → m → I, Q`), `int32` I/Q | `d_byte` fonksiyonu |
| V4 | N | `darbe × örnek` (toplantıda doğrulandı) | `track_cfg_msgs`, gönderici |
| V5 | Tetik | `0000E001` + sabit gecikme (625 clk = 5 µs), kuyruklu; HB SHOB'a verilmez | `DATA_DELAY_CLKS` |
| V6 | Birleştirme | SİFPGA iki SHOB'u **toplar** (RSİ'de `3·kod`); RSİ modeli 1/2/3 çarpanını otomatik bulur ve raporlar | RSİ modeli otomatik uyum sağlar |
| V7 | RSİ veri biçimi | `float32` I, sonra Q; değerler tamsayı değerli (düz `float(x)`) | `f32_to_int` (`sim_model_rsi.sv`) |
| V8 | RSİ belleği | seyrek, dairesel değil, pointer/BAR yok; her MSI1/MSI2'de dök + sil | — |
| V9 | RSİ kesmeleri | MSI1..MSI4 = bit 0..3 | `run_isr` (`sim_model_rsi.sv`) |
| V10 | Hüzme → RSİ dağıtımı | `1DEA0003` bayt 36/37/38 = RSİ başına hüzme sayısı; **hangi** hüzmenin hangi RSİ'ye gittiği kontrol edilmez, yalnız sayı + birleşim (hepsi tam bir kez) | — |
| V11 | RSİ adresi | `1DEA0001` index 96..119 (3 × 8 B) + `1DEA0003` offset (0/8/16); ilk (en düşük) yazılan adres bu olmalı | `track_cfg_msgs` |
| V12 | MSI7 | vektör bit 6 = SİFPGA adres atama sonrası RSY kesmesi (`0x40`); okunacak buffer yok | `run_isr` (`cpu_pkg.sv`) |
| V13 | `1DEA0003` alan konumları | offset 0/8/16, ID 24, M 28 (2 B), darbe 30 (2 B), örnek 32 (2 B), SHOB 34, mod 35, n_k 36/37/38 | `track_cfg_msgs` |
| V14 | TLP bölme | RSİ'ye yazımlar her boyutta olabilir (model birleştirir) | — |

## Açık sorular (tasarımcıya)

1. **BD'deki RX genişliği:** `Aurora_wrapper.vhd`'de `shob_*_user_data_m_axis_rx_tdata` 192 bit mi? (Eski sürümde 128 bit ve `tkeep` yoktu.)
   128 bit kalırsa üst 64 bit tasarıma hiç ulaşmaz. Tasarım RX `tkeep` kullanmıyorsa, son beat uzunluğunu `LEN`'den çıkarıyor olmalı
   (mesaj boyu 24'ün katı olmayabilir).
2. **`int32 → float32`:** düz çevrim mi, ölçekleme/kırpma var mı? Varsa RSİ modeli "HATALI örnek" der; ölçeği söylerseniz model uyarlanır.
3. **Birleştirme gerçekten toplama mı?** Değilse (ör. her SHOB farklı hüzmeler) RSİ modeli "carpan=1/2" raporlar; hangisinin doğru olduğuna siz karar verirsiniz.
4. **RSİ modelini Top'a ekleme:** `pcie_ip_rsi1..3` yanına SIM_MODE bloğu (şablon: `docs/sim_model_rsi_inst.vhd`). `pcie_ip_rsi1` port listesi
   `pcie_ip_rsy` ile aynı mı? (Şablon aynı varsayar.)
5. ~~Hüzme verisi başlık düzeni ve örnek sırası~~: ICD tablosundan doğrulandı (başlık + örnek-ana, `int32` I/Q).
6. **MSI7 (`0x40`)** ICD'de yok; "adres atama sonrası" kesmesi olarak etiketlendi. Doğru mu?
7. **Süreler:** gerçek HB periyodu, post-CPI penceresi. Senaryoda `--period-ns` ile ayarlanır (varsayılan 60 µs).
8. **Hata enjeksiyonu (MSI3/MSI4)** ve **RSY ek kesmeleri / `1DEA001B`:** ertelendi; ne zaman istenirse eklenir.

## Bilinen sınırlar

- Vivado xsim 2020.2 ile derlenmedi (ortamda yok); Verilator 5.020 ile test edildi.
- `1DEA0003` ve `1DEA0001` yalnızca **tek TLP'ye sığan ilk parça** üzerinden ayrıştırılır (bölünen mesajlarda ilk 128 B).
- Yalnız tek `0000E001` HUZPAR-HO mesajı = bir veri mesajı; Bypass (M=960) büyük N'de `DATA_MAX_BYTES` yüzünden atlanabilir.
- RSİ modeli turları sırayla eşler; MSI sayısı tur sayısıyla uyuşmazsa (ör. RSİ'den fazla/az MSI) eşleşme kayar.
