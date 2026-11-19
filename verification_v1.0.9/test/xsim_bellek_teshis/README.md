# xsim bellek teşhisi

`tb_gen_only.sv` yalnızca senaryo okuyucusunu çalıştırır (tasarım, SHOB/IUB/RSİ VIP'leri yok). Amaç, xsim'de
RAM'in nerede şiştiğini ayırmak. Verilator'da bu dosya 26 MB tepe bellekle ~0,1 sn'de okunuyor; xsim'de GB'lar
çıkıyorsa sorun ayrıştırma algoritması değil xsim'in string/dizi gösterimidir.

`run_xsim_gen_only.bat <MODE> [dosya]` (Vivado ortamında):
1. `MODE=0`: sadece `$fgets` ile satır satır okur. RAM şişerse sorun satırı string'e almakta.
2. `MODE=1`: tam ayrıştırma + mailbox'a koyma (varsayılan `$fgetc` akışlı okuma; `-testplusarg STREAM=0` ile eski `$fgets` yolu). MODE=0 temiz, MODE=1 şişiyorsa sorun ayrıştırma/paketlemede.
3. `MODE=2`: ayrıca mailbox'ı boşaltır.
Her biri için konsol çıktısı ve xsimk.exe'nin tepe RAM'i sonucu belirler. İkisi de temizse sorun senaryo okuması
değil, simülasyon sırasındadır (driver / VIP / RSİ).
