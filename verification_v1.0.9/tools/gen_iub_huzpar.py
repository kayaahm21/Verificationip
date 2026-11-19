#!/usr/bin/env python3
"""IUB HUZPAR istegi (ID 00000001) icin senaryo satiri uretir.

Veri: huzme ID (4 B) + IUB kontrol parametreleri (28+F B, rastgele) + reserved (8 B, 0)
      + M x (172*N + 20) B ADK huzpar parametreleri (rastgele).
LEN = M*(172*N+20) + 40 + F  (yalnizca veri baytlari)

Kullanim:
   python3 gen_iub_huzpar.py --m 4 --n 4 --bar 3 --huzme-id 0xA1 > huzpar_satiri.txt
   python3 gen_iub_huzpar.py --m 10 --n 24 --seed 7 > huzpar_10_24.txt   # radar boyutu (41520 B)
Cikti tek bir senaryo satiridir; input.txt'e yapistirin. Buyuk M/N icin satir cok uzun olur ve tek TLP'ye
sigmayabilir (PCIe MPS); gercek tasarimin bu mesaji nasil aldigi (cok TLP mi) ayrica netlestirilmelidir.
"""
import argparse
import random


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--m", type=int, default=4, help="ADK sayisi")
    ap.add_argument("--n", type=int, default=4, help="ADK basina cekirdek sayisi")
    ap.add_argument("--f", type=int, default=0, help="kontrol parametrelerine eklenen bayt (F)")
    ap.add_argument("--bar", type=int, default=3, help="hedef BAR")
    ap.add_argument("--huzme-id", type=lambda x: int(x, 0), default=0xA1, help="huzme ID (uint32)")
    ap.add_argument("--seed", type=int, default=20261105, help="rastgele tohum")
    a = ap.parse_args()

    rnd = random.Random(a.seed)
    huzme = [(a.huzme_id >> (8 * i)) & 0xFF for i in range(4)]       # little-endian
    ctrl = [rnd.randrange(256) for _ in range(28 + a.f)]
    rsv = [0] * 8
    adk = [rnd.randrange(256) for _ in range(a.m * (172 * a.n + 20))]
    data = huzme + ctrl + rsv + adk
    assert len(data) == a.m * (172 * a.n + 20) + 40 + a.f
    print("00000000 BAR%d 00000001 %d %s" % (a.bar, len(data), " ".join("%02X" % b for b in data)))


if __name__ == "__main__":
    main()
