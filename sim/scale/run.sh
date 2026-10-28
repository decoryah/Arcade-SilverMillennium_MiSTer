#!/bin/sh
# The framework's video_scale_int with the turned picture's sizes (Silvmil.sv's Scale for Orientation Vert), in WSL: sim/scale/run.sh
set -e
cd "$(dirname "$0")"
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
OBJ="${OBJ:-$HOME/build_silvmil_scale}"
verilator --cc --exe --build -j 2 -Wno-fatal -Wno-WIDTH -Wno-DECLFILENAME -Wno-TIMESCALEMOD -Wno-UNOPTFLAT --top-module tb_scale -Mdir $OBJ \
    ../../sys/math.sv ../../sys/video_freak.sv tb_scale.sv tb_scale.cpp > $OBJ.log 2>&1 || { grep -E "%Error" $OBJ.log | head; exit 1; }
$OBJ/Vtb_scale
