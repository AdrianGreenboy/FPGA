#!/usr/bin/env bash
# run_sram_ihp.sh: check the IHP SRAM wrapper against the FPGA SRAM model.
#   SRAM_V=<dir with RM_IHPSG13_2P_*.v> sim/run_sram_ihp.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
V="${SRAM_V:-$HOME/.ciel/ihp-sg13g2/ihp-sg13g2/libs.ref/sg13g2_sram/verilog}"
[[ -f "$V/RM_IHPSG13_2P_256x32_c2_bm_bist.v" ]] || { echo "IHP SRAM models not found - set SRAM_V="; exit 1; }
O="$HERE/build/sram_ihp"; mkdir -p "$O"
sed 's/module sram_1rw1r_32_256_8_sky130/module sram_ref/' "$HERE/rtl/fpga/sram_1rw1r_32_256_8_sky130_fpga.v" > "$O/sram_ref.v"
iverilog -g2012 -DFUNCTIONAL -s tb_sram_ihp -o "$O/tb.vvp" "$HERE/sim/tb_sram_ihp.v" \
    "$HERE/rtl/asic/ihp/sram_1rw1r_32_256_8_sky130.v" "$O/sram_ref.v" \
    "$V/RM_IHPSG13_2P_256x32_c2_bm_bist.v" "$V/RM_IHPSG13_2P_core_behavioral_bm_bist_ideal.v"
vvp -n "$O/tb.vvp" | tail -12
