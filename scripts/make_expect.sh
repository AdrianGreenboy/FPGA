#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# make_expect.sh <design> [...] : golden RTL simulation of blocks14 or one of its
# single-block variants (blk_mac14, blk_rf14, blk_bram14) -> build/bitstreams/<design>.expect
# (the selftests efpga.py / efpga_xsdb.tcl read that file next to <design>.hex)
# -----------------------------------------------------------------------------
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
[[ $# -ge 1 ]] || { echo "usage: $0 <design> [...]"; exit 1; }
[[ -f "$HERE/build/src/fabric/BlockRAM_1KB.v" ]] || "$HERE/scripts/prepare_sources.sh"
if [[ -z "${PRIMS:-}" ]]; then
    for py in python3 python3.13 python3.12; do
        PRIMS=$($py -c 'import yowasp_yosys,os;print(os.path.join(os.path.dirname(yowasp_yosys.__file__),"share","fabulous","prims.v"))' 2>/dev/null) && break
    done
fi
[[ -f "${PRIMS:-}" ]] || { echo "prims.v not found - set PRIMS=/path/to/share/fabulous/prims.v"; exit 1; }
for d in "$@"; do
    W="$HERE/build/gold/$d"; mkdir -p "$W"
    iverilog -g2012 -DBLK_NAME="$d" -s tb_golden_blocks14 -o "$W/g.vvp" \
        "$HERE/sim/tb_golden_blocks14.v" "$HERE/designs/$d.v" "$PRIMS" \
        "$HERE/build/src/fabric/BlockRAM_1KB.v" "$HERE/build/src/fabric/sram_1rw1r_32_256_8_sky130_fpga.v" \
        2>&1 | grep -Eiv "warning|timescale|inherit|macro|redefin" || true
    (cd "$W" && vvp -n g.vvp | grep -E "n=|RESULT")
    cp "$W/$d.expect" "$HERE/build/bitstreams/$d.expect"
    echo "-> build/bitstreams/$d.expect"
done
