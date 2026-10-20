#!/bin/bash
# =====================================================================
# Verilator ile v1.0.3 testlerini derler ve calistirir:
#   1) tb_cpu_check : FPGA->CPU yonu (RQ, hafiza, kesme, ISR, cikti dosyasi)
#   2) tb_cq_check  : CPU->FPGA yonu (CQ beat'leri, tkeep/tuser, HB ve bekleme zamanlamasi)
#   3) tb_fill_check: circular buffer doldurma / sarma / tasma testi
#   ./test/run_verilator.sh
# Gereken: verilator >= 5.0, python3
# Not: Verilator parametreli virtual interface'i desteklemedigi icin kaynaklar gecici bir
# klasore kopyalanip flatten_for_verilator.py ile uyarlanir. Repodaki dosyalar degismez.
# =====================================================================
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
WORK="${1:-$HERE/work}"

rm -rf "$WORK"; mkdir -p "$WORK"
cp "$ROOT"/src/*.sv "$ROOT"/tb/tb_cpu_check.sv "$ROOT"/tb/tb_cq_check.sv "$ROOT"/tb/tb_fill_check.sv "$WORK"/
cp "$ROOT"/examples/scenario_v103.txt "$ROOT"/examples/scenario_cq_test.txt "$ROOT"/examples/scenario_fill_cfg.txt "$WORK"/
python3 -I "$HERE/flatten_for_verilator.py" "$WORK"

cd "$WORK"
for TOP in tb_cpu_check tb_cq_check tb_fill_check; do
    echo "================ $TOP ================"
    verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style --top-module $TOP \
        -Mdir obj_$TOP axis_tx_if.sv beam_if.sv cpu_pkg.sv scn_pkg.sv sim_model_cpu.sv $TOP.sv
    # $error Verilator'da varsayilan olarak durdurur; xsim gibi devam etmesi icin limiti kaldiriyoruz
    ./obj_$TOP/V$TOP +verilator+error+limit+100000 | tee $TOP.log
    grep -q "TUM TESTLER GECTI" $TOP.log
done
echo "================ HEPSI GECTI ================"
