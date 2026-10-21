#!/bin/bash
# =====================================================================
# Verilator ile v1.0.4 testlerini derler ve calistirir:
#   1) tb_cpu_check : FPGA->CPU yonu (RQ, hafiza, kesme, ISR, cikti dosyasi)
#   2) tb_cq_check  : CPU->FPGA yonu (CQ beat'leri, tkeep/tuser, HB ve bekleme zamanlamasi)
#   3) tb_fill_check: circular buffer doldurma / sarma / tasma testi
#   4) tb_multi_check: 4 buffer + MSI vektoru yonlendirme
#   5) tb_aurora_check: Aurora gozlemci VIP (link, UFC TX, log)
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
cp "$ROOT"/src/*.sv "$ROOT"/src/*.v "$ROOT"/tb/tb_cpu_check.sv "$ROOT"/tb/tb_multi_check.sv "$ROOT"/tb/tb_cq_check.sv "$ROOT"/tb/tb_fill_check.sv "$ROOT"/tb/tb_aurora_check.sv "$WORK"/
cp "$ROOT"/examples/scenario_v103.txt "$ROOT"/examples/scenario_v104.txt "$ROOT"/examples/scenario_cq_test.txt "$ROOT"/examples/scenario_fill_cfg.txt "$WORK"/
python3 -I "$HERE/flatten_for_verilator.py" "$WORK"

cd "$WORK"
for TOP in tb_cpu_check tb_multi_check tb_cq_check tb_fill_check; do
    echo "================ $TOP ================"
    verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style --top-module $TOP \
        -Mdir obj_$TOP axis_tx_if.sv beam_if.sv cpu_pkg.sv scn_pkg.sv sim_model_cpu.sv $TOP.sv
    # $error Verilator'da varsayilan olarak durdurur; xsim gibi devam etmesi icin limiti kaldiriyoruz
    ./obj_$TOP/V$TOP +verilator+error+limit+100000 | tee $TOP.log
    grep -q "TUM TESTLER GECTI" $TOP.log
done
# Aurora gozlemci VIP (duz Verilog; davranis icin VIP_BEHAVIORAL tanimli)
TOP=tb_aurora_check
echo "================ $TOP ================"
verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -DVIP_BEHAVIORAL=1 --top-module $TOP \
    -Mdir obj_$TOP aurora_64b66b_vip.v $TOP.sv
./obj_$TOP/V$TOP | tee $TOP.log
grep -q "TUM TESTLER GECTI" $TOP.log
# Alternatif SystemVerilog surumu (alt/aurora_64b66b_vip.sv) ayni testten gecmeli
cp "$ROOT"/alt/aurora_64b66b_vip.sv "$WORK"/aurora_64b66b_vip_alt.sv
verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -DVIP_BEHAVIORAL=1 --top-module $TOP \
    -Mdir obj_${TOP}_sv aurora_64b66b_vip_alt.sv $TOP.sv
./obj_${TOP}_sv/V$TOP | tee ${TOP}_sv.log
grep -q "TUM TESTLER GECTI" ${TOP}_sv.log
# Sade govde (VIP_BEHAVIORAL tanimsiz) sadece lint'ten gecmeli
verilator --lint-only -Wno-fatal -Wno-style --top-module aurora_64b66b_vip aurora_64b66b_vip.v
echo "================ HEPSI GECTI ================"
