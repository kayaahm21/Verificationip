#!/usr/bin/env python3
"""Cok turlu huzme senaryosu uretir (v1.0.7): adres atama + her tur icin SIFPGA/SHOB/IUB huzparlari + HB zamanlamasi.

Cikti, CPU VIP'in senaryo dosyasidir (INPUT_FILE / +TLP_FILE). Sira:

  1) 1DEA0001 (PCIe adres atama, BAR0): 4 buffer + RSI1/2/3 veri baslangic adresleri (index 96..119) + RSI sayisi + kesme araligi
  2) Her tur icin:
       77777777 <period_ns>        bir sonraki HB'yi planla (bu turun HB'si)
       1DEA0003 (SIFPGA huzpar, BAR0): RSI offset'leri, huzme ID, M, darbe, ornek, RSI basina indirilecek huzme sayisi
       0000E001 (SHOB-1 huzpar, BAR1)  -> SHOB-1 VIP DATA_DELAY sonra huzme verisini (00000002) SIFPGA'ya basar
       0000E001 (SHOB-2 huzpar, BAR2)  -> ayni
       00000001 (IUB huzpar,   BAR3)   -> IUB cevabi (00000002) beklenir
       99999999                        HB gelene kadar bekle (tur suresi)

Tur parametreleri (--round, tekrarlanabilir):  M,DARBE,ORNEK[,n1,n2,n3]
  n1,n2,n3 verilmezse M, 3'e esite yakin bolunur (artanlar once RSI1'e).
  HO'da M 4..96 arasinda ve 4'un kati; ORNEK 4'un kati; n1+n2+n3 = M olmali. N = DARBE x ORNEK.

Ornekler:
  python3 gen_huzme_rounds.py > input_huzme_turlari.txt                      # 3 varsayilan tur
  python3 gen_huzme_rounds.py --round 8,2,4 --round 12,1,8,4,4,4 --period-ns 60000 > x.txt
  python3 gen_huzme_rounds.py --offset-mode step --offset-step 0x1000 ...   # her tur offset 0x1000 kayar
Katsayilar ve IUB verisi rastgeledir (sabit tohum); HUZPAR katsayilari SHOB'u etkilemez.
"""
import argparse
import random


def le(v, n):
    return [(v >> (8 * i)) & 0xFF for i in range(n)]


def line(bar, msg_id, data):
    bar_s = "" if bar == 0 else " BAR%d" % bar
    return "00000000%s %s %d %s" % (bar_s, msg_id, len(data), " ".join("%02X" % b for b in data))


def split3(m):
    base, rem = divmod(m, 3)
    return [base + (1 if i < rem else 0) for i in range(3)]


def shob_huzpar(huzme_id, m, darbe, ornek, rnd):
    data = le(huzme_id, 4) + le(0x01, 2) + le(m, 2) + le(darbe, 4) + le(ornek, 4)
    for _ in range(4):
        data += le(0x3FFFFFFF, 4)
    data += [0x01, 0x00] + [0] * 22
    assert len(data) == 56
    for _ in range(m * 120 * 4 * 2):
        data += le(rnd.randrange(-2048, 2048) & 0xFFFF, 2)
    return data


def iub_huzpar(huzme_id, rnd, m=4, n=4):
    data = le(huzme_id, 4) + [rnd.randrange(256) for _ in range(28)] + [0] * 8
    data += [rnd.randrange(256) for _ in range(m * (172 * n + 20))]
    return data


def sifpga_huzpar(offsets, huzme_id, m, darbe, ornek, nk):
    data = []
    for o in offsets:
        data += le(o, 8)
    data += le(huzme_id, 4) + le(m, 2) + le(darbe, 2) + le(ornek, 2)
    data += [0x03, 0x00]                    # SHOB kullanimi (bit0 SHOB-1, bit1 SHOB-2), mod (0 HO)
    data += [nk[0], nk[1], nk[2]]
    data += [0] * 17
    assert len(data) == 56
    return data


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--round", action="append", default=[], help="M,DARBE,ORNEK[,n1,n2,n3] (tekrarlanabilir)")
    ap.add_argument("--period-ns", type=int, default=60000,
                    help="tur suresi (ns): HB planlama araligi; SHOB verisi + RSI yazimi bu surede bitmeli")
    ap.add_argument("--huzme-id", type=lambda x: int(x, 0), default=0xA001, help="ilk turun huzme ID'si (her tur +1)")
    ap.add_argument("--rsi-start", default="0x10000000,0x20000000,0x30000000",
                    help="RSI1/2/3 veri baslangic adresleri (1DEA0001 index 96..119)")
    ap.add_argument("--offset-mode", choices=["fixed", "step"], default="fixed",
                    help="fixed: her tur ayni offset; step: her tur --offset-step kadar kayar")
    ap.add_argument("--offset-step", type=lambda x: int(x, 0), default=0x1000)
    ap.add_argument("--offsets", default="0x0,0x0,0x0", help="ilk tur RSI1/2/3 offset (4'un kati)")
    ap.add_argument("--rsi-count", type=int, default=3)
    ap.add_argument("--irq-interval-us", type=int, default=16, help="RSY kesme araligi (1DEA0001 index 121)")
    ap.add_argument("--seed", type=int, default=20261105)
    ap.add_argument("--iub-m", type=int, default=4)
    ap.add_argument("--iub-n", type=int, default=4)
    a = ap.parse_args()

    rounds = a.round or ["8,2,4", "4,1,4", "12,2,4"]
    rnd = random.Random(a.seed)
    rsi_start = [int(x, 0) for x in a.rsi_start.split(",")]
    off0 = [int(x, 0) for x in a.offsets.split(",")]
    if len(rsi_start) != 3 or len(off0) != 3 or any(o % 4 for o in off0):
        raise SystemExit("--rsi-start ve --offsets 3 deger icermeli; offset'ler 4'un kati olmali")

    out = []
    out.append("# v1.0.7: cok turlu huzme senaryosu (gen_huzme_rounds.py ile uretildi)")
    out.append("# Sira: 1DEA0001 adres atama; her tur: HB planla, 1DEA0003, SHOB-1/2 E001, IUB 00000001, HB bekle")

    # 1DEA0001: 4 buffer (SIFPGA, SHOB1, SHOB2, IUB) + RSI adresleri + RSI sayisi + kesme araligi
    cfg = []
    for base, size, ptr in [(0x10000, 4096, 0x20000), (0x30000, 4096, 0x40000),
                            (0x50000, 4096, 0x60000), (0x70000, 4096, 0x80000)]:
        cfg += le(base, 8) + le(size, 8) + le(ptr, 8)
    for s in rsi_start:
        cfg += le(s, 8)
    cfg += [a.rsi_count & 0xFF, a.irq_interval_us & 0xFF, 0, 0]
    assert len(cfg) == 124
    out.append("# --- adres atama (RSI baslangic adresleri index 96..119) ---")
    out.append(line(0, "1DEA0001", cfg))
    out.append("88888888 2000")

    for r, spec in enumerate(rounds):
        p = [int(x) for x in spec.split(",")]
        if len(p) not in (3, 6):
            raise SystemExit("--round M,DARBE,ORNEK[,n1,n2,n3]: %r" % spec)
        m, darbe, ornek = p[0], p[1], p[2]
        nk = p[3:6] if len(p) == 6 else split3(m)
        if m < 4 or m > 96 or m % 4:
            raise SystemExit("tur %d: M 4..96 arasi ve 4'un kati olmali: %d" % (r + 1, m))
        if darbe <= 0 or ornek <= 0 or ornek % 4:
            raise SystemExit("tur %d: darbe > 0, ornek > 0 ve 4'un kati olmali" % (r + 1))
        if sum(nk) != m:
            raise SystemExit("tur %d: n1+n2+n3 (%d) M'ye (%d) esit olmali" % (r + 1, sum(nk), m))
        hid = a.huzme_id + r
        offs = [o + (r * a.offset_step if a.offset_mode == "step" else 0) for o in off0]
        out.append("")
        out.append("# --- TUR %d: M=%d darbe=%d ornek=%d N=%d  RSI basina huzme=%d/%d/%d  huzme_id=0x%X ---"
                   % (r + 1, m, darbe, ornek, darbe * ornek, nk[0], nk[1], nk[2], hid))
        out.append("77777777 %d" % a.period_ns)
        out.append(line(0, "1DEA0003", sifpga_huzpar(offs, hid, m, darbe, ornek, nk)))
        out.append(line(1, "0000E001", shob_huzpar(hid, m, darbe, ornek, rnd)))
        out.append(line(2, "0000E001", shob_huzpar(hid, m, darbe, ornek, rnd)))
        out.append(line(3, "00000001", iub_huzpar(hid, rnd, a.iub_m, a.iub_n)))
        out.append("99999999")

    print("\n".join(out))


if __name__ == "__main__":
    main()
