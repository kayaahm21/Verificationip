#!/bin/bash
# =====================================================================
# Verilator ile v1.0.7 testlerini derler ve calistirir:
#   1) tb_cpu_check : FPGA->CPU yonu (RQ, hafiza, kesme, ISR, cikti dosyasi)
#   2) tb_cq_check  : CPU->FPGA yonu (CQ beat'leri, tkeep/tuser, HB ve bekleme zamanlamasi)
#   3) tb_fill_check: circular buffer doldurma / sarma / tasma testi
#   4) tb_multi_check: 4 buffer + MSI vektoru yonlendirme
#   5) tb_aurora_check: Aurora gozlemci VIP (link, UFC TX, log)
#   6) tb_aurora8b_check: Aurora 8b10b (IUB)
#   7) tb_shob_data_check: SHOB huzme verisi (0x00000002) gondericisi, 192 bit
#   8) tb_rsi_check: RSI modelleri (x3), dogrulama, birlestirme kurali, hata yakalama
#   9) tb_scn_rsi_check: senaryo -> surucu -> paylasilan RSI durumu (1DEA0001/1DEA0003)
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
cp "$ROOT"/src/*.sv "$ROOT"/src/*.v "$ROOT"/tb/tb_cpu_check.sv "$ROOT"/tb/tb_multi_check.sv "$ROOT"/tb/tb_cq_check.sv "$ROOT"/tb/tb_fill_check.sv "$ROOT"/tb/tb_aurora_check.sv "$ROOT"/tb/tb_aurora8b_check.sv "$ROOT"/tb/tb_shob_data_check.sv "$ROOT"/tb/tb_rsi_check.sv "$ROOT"/tb/tb_scn_rsi_check.sv "$WORK"/
python3 -I "$ROOT"/tools/gen_huzme_rounds.py --round 4,1,4 --round 8,1,4 --period-ns 20000 --offset-mode step --offset-step 0x100 > "$WORK"/scenario_huzme_test.txt
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
# Aurora gozlemci VIP (duz Verilog; davranis varsayilan olarak acik)
TOP=tb_aurora_check
echo "================ $TOP ================"
verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style --top-module $TOP \
    -Mdir obj_$TOP aurora_64b66b_vip.v $TOP.sv
./obj_$TOP/V$TOP | tee $TOP.log
grep -q "TUM TESTLER GECTI" $TOP.log
# Aurora 8b10b gozlemci VIP (IUB)
TOP=tb_aurora8b_check
echo "================ $TOP ================"
verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style --top-module $TOP \
    -Mdir obj_$TOP aurora_8b10b_vip.v $TOP.sv
./obj_$TOP/V$TOP | tee $TOP.log
grep -q "TUM TESTLER GECTI" $TOP.log
verilator --lint-only -Wno-fatal -Wno-style -DVIP_STUB --top-module aurora_8b10b_vip aurora_8b10b_vip.v
TOP=tb_aurora_check
# Sade govde (VIP_STUB) sadece lint'ten gecmeli
verilator --lint-only -Wno-fatal -Wno-style -DVIP_STUB --top-module aurora_64b66b_vip aurora_64b66b_vip.v

# SHOB huzme verisi gondericisi (192 bit, 0x00000002)
TOP=tb_shob_data_check
echo "================ $TOP ================"
verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -Wno-INITIALDLY --top-module $TOP \
    -Mdir obj_$TOP aurora_64b66b_vip.v $TOP.sv
./obj_$TOP/V$TOP | tee $TOP.log
grep -q "TUM TESTLER GECTI" $TOP.log
# RSI modelleri (yalniz cpu_pkg + sim_model_rsi gerekir)
TOP=tb_rsi_check
echo "================ $TOP ================"
verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -Wno-INITIALDLY --top-module $TOP \
    -Mdir obj_$TOP cpu_pkg.sv sim_model_rsi.sv $TOP.sv
./obj_$TOP/V$TOP +verilator+error+limit+100000 | tee $TOP.log
grep -q "TUM TESTLER GECTI" $TOP.log
# Senaryo -> surucu -> RSI paylasilan durumu
TOP=tb_scn_rsi_check
echo "================ $TOP ================"
verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -Wno-INITIALDLY --top-module $TOP \
    -Mdir obj_$TOP axis_tx_if.sv beam_if.sv cpu_pkg.sv scn_pkg.sv sim_model_cpu.sv $TOP.sv
./obj_$TOP/V$TOP +verilator+error+limit+100000 | tee $TOP.log
grep -q "TUM TESTLER GECTI" $TOP.log
echo "================ HEPSI GECTI ================"
