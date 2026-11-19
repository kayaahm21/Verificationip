#!/usr/bin/env python3
"""Verilator 5.020 parametreli sanal arayuzu (virtual interface) desteklemiyor.
Bu betik, SADECE test icin, verilen klasordeki kopyalarda axis_tx_if'i parametresiz hale getirir.
Repodaki gercek kaynaklar (xsim/Vivado icin) degistirilmez.

Kullanim: python3 -I flatten_for_verilator.py <klasor>
"""
import re
import sys
from pathlib import Path

d = Path(sys.argv[1])

# 1) Interface: parametreleri localparam yap
p = d / "axis_tx_if.sv"
s = p.read_text()
s = re.sub(r"interface axis_tx_if #\(.*?\)\(", "interface axis_tx_if (", s, flags=re.S)
s = s.replace("localparam int KEEP_WIDTH",
              "localparam int DATA_WIDTH = 256, TUSER_WIDTH = 88, KEEP_GRAN = 4;\n    localparam int KEEP_WIDTH")
p.write_text(s)

# 2) Siniflardaki virtual interface tipi
p = d / "scn_pkg.sv"
s = p.read_text()
s = s.replace("virtual axis_tx_if #(DATA_WIDTH, TUSER_WIDTH, KEEP_GRAN)", "virtual axis_tx_if")
p.write_text(s)

# 3) Instance
p = d / "sim_model_cpu.sv"
s = p.read_text()
s = re.sub(r"axis_tx_if #\(.*?\)\s*cq_if", "axis_tx_if cq_if", s, flags=re.S)
p.write_text(s)
