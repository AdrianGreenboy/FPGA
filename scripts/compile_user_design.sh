#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# compile_user_design.sh <design.v> [more.v ...]
#   Synthesise + place & route + bitgen a user design for the efpga_v0 fabric.
#
# Contract for the user design (same as the demos in fabric/user_design/):
#   module <name> (input clk, input [15:0] io_in, output [15:0] io_out,
#                  output [15:0] io_oeb);      // io_oeb[i]=1 -> pin i is an input
#   <name> must equal the file name of the first argument.
#
# Outputs in build/bitstreams/:  <name>.bin  <name>.hex  <name>.h  <name>_npnr.log
# Needs: FABulous (python 3.12 venv), yosys <= 0.66 (0.67+ dropped share/fabulous),
#        nextpnr-generic with --uarch fabulous
# -----------------------------------------------------------------------------
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
FAB="$HERE/fabric"
OUT="$HERE/build/bitstreams"
[[ $# -ge 1 ]] || { sed -n '2,14p' "$0"; exit 1; }
mkdir -p "$OUT" "$FAB/user_design"

SRC=$(realpath "$1"); shift
NAME=$(basename "$SRC" .v)
EXTRA=(); for f in "$@"; do EXTRA+=("$(realpath "$f")"); done

YV=$(yosys -V | sed -E 's/^Yosys ([0-9]+)\.([0-9]+).*/\1 \2/')
read -r YMAJ YMIN <<< "$YV"
if (( YMAJ == 0 && YMIN > 66 )); then
    echo "ERROR: yosys 0.$YMIN has no share/fabulous prims; use yosys 0.66 (pip install 'yowasp-yosys==0.66.*')"
    exit 1
fi

WORK="$FAB/user_design"
cp "$SRC" "$WORK/$NAME.v"
for f in "${EXTRA[@]}"; do cp "$f" "$WORK/"; done

cd "$FAB"
# 1) wrapper with every IO bel; FABulous leaves the port connections empty for
#    non-demo designs, so connect io_in/io_out/io_oeb to the IO bel buses here.
FABulous -p . run "load_fabric; gen_user_design_wrapper user_design/$NAME.v user_design/top_wrapper.v" > "$OUT/${NAME}_fab.log" 2>&1
sed -i "s/\.io_in(), \.io_out(), \.io_oeb()/.io_in(IO_1_bidirectional_frame_config_pass_O), .io_out(IO_1_bidirectional_frame_config_pass_I), .io_oeb(IO_1_bidirectional_frame_config_pass_T)/" user_design/top_wrapper.v
grep -q "io_in(IO_1_bidirectional_frame_config_pass_O)" user_design/top_wrapper.v \
    || { echo "ERROR: could not patch top_wrapper.v (did the FABulous wrapper format change?)"; exit 1; }

# 2) synth + PnR + bitgen
DESIGN_FILES="user_design/$NAME.v"
for f in "${EXTRA[@]}"; do DESIGN_FILES+=" user_design/$(basename "$f")"; done
if ! FABulous -p . run "load_fabric; compile_design $DESIGN_FILES" >> "$OUT/${NAME}_fab.log" 2>&1; then
    grep -E "ERROR" "$OUT/${NAME}_fab.log" | tail -5
    echo "compile failed - full log: $OUT/${NAME}_fab.log"; exit 1
fi

cp "user_design/$NAME.bin" "$OUT/"
cp "user_design/${NAME}_npnr_log.txt" "$OUT/${NAME}_npnr.log"
python3 "$HERE/scripts/bin2words.py" "$OUT/$NAME.bin" "$OUT/$NAME.hex"
python3 "$HERE/scripts/bin2words.py" "$OUT/$NAME.bin" "$OUT/$NAME.h" --fmt c --name "bs_$NAME"
grep -E "^Info:\s+(FABULOUS_LC|MULADD|RegFile_32x4):\s+[0-9]+/" "$OUT/${NAME}_npnr.log" | sed -E 's/^Info:\s+/  /'
grep -E "Max frequency" "$OUT/${NAME}_npnr.log" | tail -1 | sed 's/^Info: */  nextpnr model (not Versal timing): /'
