#!/usr/bin/env python3
"""SHOB-1/SHOB-2 "HUZPAR ve KATSAYILAR" (ID 0000E001) icin senaryo satiri uretir.

Mesaj verisi (index, boyut, tip) - hepsi little-endian:
   0   4  uint32  Huzme ID
   4   2  uint16  SHOB sinyal isleme durumu (0x00 Bypass, 0x01 HO)
   6   2  uint16  SHOB alma huzmesi sayisi (HO: 4..96 (4'er adim), Bypass: 960)
   8   4  uint32  Darbe sayisi (>0)
   12  4  uint32  Darbedeki ornek sayisi (>0, 4'un kati)
   16  4  uint32  GAC 1-30   kullanim maskesi (bit 30,31 reserved)
   20  4  uint32  GAC 31-60  kullanim maskesi
   24  4  uint32  GAC 61-90  kullanim maskesi
   28  4  uint32  GAC 91-120 kullanim maskesi
   32  1  uint8   SHOB kart kullanim durumu (bit0 HO, bit1-3 HI-1..3)
   33  1  uint8   SHOB test modu (0 HO, 1 HI)
   34  22 uint8   Reserved (0)
   56  ...        Katsayilar: M huzme x 120 GAC x 4 kanal x (I, Q) x int16 = M*1920 bayt
                  (Bypass'ta katsayi YOK, LEN = 56)
LEN = 56 + M*1920 (HO)  |  56 (Bypass)

Mesaj (ID+LEN+veri) 32 DWORD'dan (128 bayt) buyuk oldugu icin VIP'in senaryo ayristiricisi tarafindan OTOMATIK
olarak 32 DWORD'luk paketlere bolunur (ID+LEN basligi yalnizca ilk pakette, adres 0, paketler art arda).

Kullanim:
   python3 gen_shob_huzpar.py --bar 1 > shob1_satiri.txt           # HO, M=4, darbe=4, ornek=4
   python3 gen_shob_huzpar.py --bar 2 --mode bypass > shob2.txt     # Bypass (katsayi yok)
   python3 gen_shob_huzpar.py --bar 1 --m 96 --seed 3 > buyuk.txt   # en buyuk HO mesaji (184376 B)
Katsayilar rastgele int16 (sabit tohum) uretilir; katsayi SIRASI rastgele oldugu icin onemli degildir.
"""
import argparse
import random


def le(v, n):
    return [(v >> (8 * i)) & 0xFF for i in range(n)]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bar", type=int, default=1, help="hedef BAR (SHOB-1: 1, SHOB-2: 2)")
    ap.add_argument("--mode", choices=["ho", "bypass"], default="ho", help="SHOB sinyal isleme durumu")
    ap.add_argument("--m", type=int, default=4, help="alma huzmesi sayisi (HO: 4..96, 4'er adim)")
    ap.add_argument("--pulses", type=int, default=4, help="darbe sayisi")
    ap.add_argument("--samples", type=int, default=4, help="darbedeki ornek sayisi (4'un kati)")
    ap.add_argument("--huzme-id", type=lambda x: int(x, 0), default=0x01, help="huzme ID (uint32)")
    ap.add_argument("--gac-masks", default="0x3FFFFFFF,0x3FFFFFFF,0x3FFFFFFF,0x3FFFFFFF",
                    help="4 GAC kullanim maskesi (virgulle ayrilmis)")
    ap.add_argument("--card", type=lambda x: int(x, 0), default=0x01, help="SHOB kart kullanim durumu")
    ap.add_argument("--test-mode", type=int, default=0, help="SHOB test modu (0 HO, 1 HI)")
    ap.add_argument("--seed", type=int, default=20261105, help="rastgele tohum (katsayilar)")
    a = ap.parse_args()

    if a.mode == "ho" and (a.m < 4 or a.m > 96 or a.m % 4):
        raise SystemExit("HO modunda --m 4..96 arasinda ve 4'un kati olmali")
    if a.samples <= 0 or a.samples % 4 or a.pulses <= 0:
        raise SystemExit("--pulses > 0 ve --samples > 0, 4'un kati olmali")
    masks = [int(x, 0) for x in a.gac_masks.split(",")]
    if len(masks) != 4 or any(m & 0xC0000000 for m in masks):
        raise SystemExit("4 GAC maskesi gerekli; bit 30 ve 31 reserved (0 olmali)")
    if a.test_mode == 1 and (a.card & 0x0E):
        raise SystemExit("test modu 1 iken HI kullanim durumlari (kart bit1-3) 0 olmali")

    rnd = random.Random(a.seed)
    bypass = (a.mode == "bypass")
    nbeam = 960 if bypass else a.m

    data = []
    data += le(a.huzme_id, 4)
    data += le(0x00 if bypass else 0x01, 2)
    data += le(nbeam, 2)
    data += le(a.pulses, 4)
    data += le(a.samples, 4)
    for m in masks:
        data += le(m, 4)
    data += [a.card & 0xFF, a.test_mode & 0xFF]
    data += [0] * 22
    assert len(data) == 56
    if not bypass:
        for _ in range(a.m * 120 * 4 * 2):               # huzme x GAC x kanal x (I,Q)
            data += le(rnd.randrange(-2048, 2048) & 0xFFFF, 2)   # int16 (little-endian)
        assert len(data) == 56 + a.m * 1920

    print("00000000 BAR%d 0000E001 %d %s" % (a.bar, len(data), " ".join("%02X" % b for b in data)))


if __name__ == "__main__":
    main()
