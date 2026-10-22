#!/usr/bin/env python3
"""Buffer doldurma / sarma testi icin senaryo dosyasi uretir.

Senaryo, kullanicinin ornegindeki mesajlari tekrar eder:
   1DEA0005 (FPGA cevabi ~24 bayt), 1DEA0007 (~72), 1DEA000B (~16), 1DEA0F09 (~12)
Bir "tur" boyunca FPGA'nin buffer'a yazacagi veri yaklasik 24+72+16+12 = 124 bayttir.
(Cevap boyutlari onceki bir rq_trace.txt'ten cikarildi; tasarim farkli cevap veriyorsa
 --rounds ve --size degerlerini rq_trace.txt'e gore ayarlayin.)

Kullanim:
   python3 gen_buffer_fill.py --size 256 --rounds 8 --out buffer_fill_small.txt
   python3 gen_buffer_fill.py --size 4096 --rounds 36 --gap-ns 30000 --out buffer_fill_4k.txt

Not: Islemci modeli, FPGA'ya "okuma pointer'i" bildirmez; FPGA okunmamis verinin ustune yazabilir.
Bu yuzden mesajlar arasi bekleme (--gap-ns), tasarimin kesme gecikmesinden (~17 us) uzun olmali.
Tasma olursa model "BUFFER TASTI" uyarisi verir.
"""
import argparse


def le(value, n):
    return " ".join(f"{(value >> (8 * i)) & 0xFF:02X}" for i in range(n))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base", type=lambda x: int(x, 0), default=0x10000, help="buffer baslangic adresi")
    ap.add_argument("--size", type=lambda x: int(x, 0), default=256, help="buffer boyutu (bayt, 4'un kati)")
    ap.add_argument("--ptr", type=lambda x: int(x, 0), default=0x20000, help="pointer adresi")
    ap.add_argument("--rounds", type=int, default=8, help="tekrar sayisi")
    ap.add_argument("--init-wait-ns", type=int, default=400000, help="config sonrasi ilk bekleme (ns)")
    ap.add_argument("--hb-ns", type=int, default=20000, help="her turda HB'nin planlanma gecikmesi (ns)")
    ap.add_argument("--gap-ns", type=int, default=50000, help="mesaj gruplari arasi bekleme (ns)")
    ap.add_argument("--out", required=True, help="cikti dosyasi")
    a = ap.parse_args()

    if a.size % 4:
        raise SystemExit("--size 4'un kati olmali")

    # 1DEA0001 verisi (v1.0.4): 4 x (base, size, ptr_addr), little-endian; SIFPGA, SHOB1, SHOB2, IUB.
    # Yalnizca SIFPGA acik; digerleri size=0 (kapali).
    off = " ".join(["00"] * 24)
    cfg = f"00000000 1DEA0001 124 {le(a.base, 8)} {le(a.size, 8)} {le(a.ptr, 8)} {off} {off} {off} {" ".join(["00"] * 28)}"

    lines = [
        "# =====================================================================",
        "# Buffer doldurma / sarma testi (tools/gen_buffer_fill.py ile uretildi)",
        f"#   buffer base=0x{a.base:X} size={a.size} ptr_adresi=0x{a.ptr:X}, {a.rounds} tur",
        "#   bir tur: 1DEA0005, (HB), 1DEA0007, 1DEA000B, 1DEA0F09  -> ~124 bayt cevap",
        "# =====================================================================",
        cfg,
        f"88888888 {a.init_wait_ns}",
    ]
    for r in range(a.rounds):
        lines += [
            f"# ---- tur {r + 1} ----",
            "00000000 1DEA0005 0",
            f"88888888 {a.gap_ns}",
            f"77777777 {a.hb_ns}",
            "99999999",
            "00000000 1DEA0007 0",
            "00000000 1DEA000B 0",
            "00000000 1DEA0F09 0",
            f"88888888 {a.gap_ns}",
        ]
    with open(a.out, "w") as f:
        f.write("\n".join(lines) + "\n")

    total = 8 + a.rounds * 124
    print(f"{a.out}: {a.rounds} tur, tahmini toplam cevap ~{total} bayt "
          f"(buffer {a.size} bayt -> yaklasik {total // a.size} kez tam doluluk/sarma)")


if __name__ == "__main__":
    main()
