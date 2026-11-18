@echo off
REM Kullanim:  run_xsim_gen_only.bat <MODE 0|1|2> <senaryo dosyasi (ileri egik cizgi)>
REM Calistirirken Gorev Yoneticisi'nde xsimk.exe'nin RAM'ine bak; GB'lar artiyorsa Ctrl+C ile durdur.
REM Gereken: Vivado ortami (xvlog/xelab/xsim PATH'te). src klasoru ..\..\src
set MODE=%1
set F=%2
if "%MODE%"=="" set MODE=0
if "%F%"=="" set F=../../examples/input_huzme_MAX_tek_huzme.txt
set SRC=..\..\src
call xvlog -sv %SRC%\axis_tx_if.sv %SRC%\beam_if.sv %SRC%\cpu_pkg.sv %SRC%\rsi_pkg.sv %SRC%\scn_pkg.sv tb_gen_only.sv
call xelab tb_gen_only -s gen_only -debug off
call xsim gen_only -R -testplusarg MODE=%MODE% -testplusarg F=%F%
