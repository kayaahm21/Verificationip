#!/usr/bin/env python3
"""Rastgele parametreli cok turlu huzme senaryosu uretir (v1.0.8).

Tur sirasi (1DEA0001 bir kez; her tur): 77777777, 1DEA0003, IUB 00000001 (BAR3), SHOB-1 E001 (BAR1), SHOB-2 E001 (BAR2),
99999999; ek olarak her turun HB'sinden sonra 20 veya 30 us (rastgele) bekleme (88888888) konur.

Rastgele secilenler (sabit tohumla tekrarlanabilir): M (4'un kati), darbe, ornek (4'un kati), RSI basina huzme sayilari
(n1+n2+n3 = M, her biri >= 1), bekleme (20/30 us). Huzme ID'si her turda +1 artar.
HB periyodu M'ye gore secilir (hüzpar'lar HB'den once varmali): max(60 us, 20 us + 3 us x M).

Ornek:
  python3 gen_huzme_random.py > ../examples/input_huzme_100_rastgele.txt
  python3 gen_huzme_random.py --count 20 --m-max 16 --seed 7 > x.txt
"""
import argparse
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_huzme_rounds import le, line, shob_huzpar, iub_huzpar, sifpga_huzpar  # noqa: E402


def split_random(m, rnd):
    """m'yi 3 pozitif parcaya boler."""
    a, b = sorted(rnd.sample(range(1, m), 2))
    return [a, b - a, m - b]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--count", type=int, default=100, help="tur (huzme) sayisi")
    ap.add_argument("--seed", type=int, default=20261118)
    ap.add_argument("--m-max", type=int, default=16, help="en buyuk M (4'un kati, <= 96)")
    ap.add_argument("--darbe-max", type=int, default=4)
    ap.add_argument("--ornek-max", type=int, default=32, help="en buyuk ornek (4'un kati)")
    ap.add_argument("--gaps-us", default="20,30", help="turlar arasi bekleme secenekleri (us, virgulle)")
    ap.add_argument("--huzme-id", type=lambda x: int(x, 0), default=0xA001)
    ap.add_argument("--rsi-start", default="0x10000000,0x20000000,0x30000000")
    ap.add_argument("--rsi-count", type=int, default=3)
    ap.add_argument("--irq-interval-us", type=int, default=16)
    ap.add_argument("--iub-n", type=int, default=4)
    a = ap.parse_args()

    if a.m_max < 4 or a.m_max > 96 or a.m_max % 4 or a.ornek_max < 4 or a.ornek_max % 4:
        raise SystemExit("--m-max 4..96 ve 4'un kati, --ornek-max 4'un kati olmali")
    prm = random.Random(a.seed)          # tur parametreleri
    rnd = random.Random(a.seed + 1)      # huzpar katsayilari / IUB verisi
    gaps = [int(x) for x in a.gaps_us.split(",")]
    rsi_start = [int(x, 0) for x in a.rsi_start.split(",")]

    out = []
    out.append("# v1.0.8: %d turluk rastgele huzme senaryosu (gen_huzme_random.py, tohum=%d)" % (a.count, a.seed))
    out.append("# Her tur: HB planla, 1DEA0003, IUB 00000001, SHOB-1/2 E001, HB bekle, 20/30 us bekle")

    cfg = []
    for base, size, ptr in [(0x10000, 4096, 0x20000), (0x30000, 4096, 0x40000),
                            (0x50000, 4096, 0x60000), (0x70000, 4096, 0x80000)]:
        cfg += le(base, 8) + le(size, 8) + le(ptr, 8)
    for s in rsi_start:
        cfg += le(s, 8)
    cfg += [a.rsi_count & 0xFF, a.irq_interval_us & 0xFF, 0, 0]
    assert len(cfg) == 124
    out.append("# --- adres atama ---")
    out.append(line(0, "1DEA0001", cfg))
    out.append("88888888 2000")

    for r in range(a.count):
        m = prm.choice(range(4, a.m_max + 1, 4))
        darbe = prm.randint(1, a.darbe_max)
        ornek = prm.choice(range(4, a.ornek_max + 1, 4))
        nk = split_random(m, prm)
        gap_us = prm.choice(gaps)
        period_ns = max(60000, 20000 + 3000 * m)
        hid = a.huzme_id + r
        out.append("")
        out.append("# --- TUR %d: M=%d darbe=%d ornek=%d N=%d  RSI basina huzme=%d/%d/%d  huzme_id=0x%X  HB=%d us  sonra %d us bekle ---"
                   % (r + 1, m, darbe, ornek, darbe * ornek, nk[0], nk[1], nk[2], hid, period_ns // 1000, gap_us))
        out.append("77777777 %d" % period_ns)
        out.append(line(0, "1DEA0003", sifpga_huzpar([0, 0, 0], hid, m, darbe, ornek, nk)))
        out.append(line(3, "00000001", iub_huzpar(hid, rnd, m, a.iub_n)))          # IUB (BAR3) SHOB'lardan once
        out.append(line(1, "0000E001", shob_huzpar(hid, m, darbe, ornek, rnd)))
        out.append(line(2, "0000E001", shob_huzpar(hid, m, darbe, ornek, rnd)))
        out.append("99999999")
        out.append("88888888 %d" % (gap_us * 1000))

    out.append("")
    out.append("# --- son tur verisinin ve RSI yazimlarinin bitmesi icin ---")
    out.append("88888888 100000")
    print("\n".join(out))


if __name__ == "__main__":
    main()
