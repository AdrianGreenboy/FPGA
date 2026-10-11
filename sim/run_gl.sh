#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# run_gl.sh : gate-level simulation of the HARDENED fabric (IHP SG13G2) against
#             the same golden expectations used on Versal silicon.
#
#   sim/run_gl.sh [design ...]          default: counter14 lfsr14 blocks14p
#   MAXN=1000 sim/run_gl.sh ...         only check n <= 1000 (much faster)
#   CELLS=/path/sg13g2_stdcell.v ...    override the PDK cell models
#   GL_SCRUB=full ...                   also scrub tile-internal X (see below)
#   TIMEOUT=3600 ...                    per-design wall-clock limit (s)
#
# What is simulated:
#   behavioural wrapper  : eFPGA_top, ConfigFSM, Frame_*, config UART/bitbang,
#                          BlockRAM_1KB + FPGA SRAM model (from build/src)
#   gate level           : Fabric/macro/final_views/nl/eFPGA.nl.v (stitched
#                          fabric) + every Tile/*/macro/final_views/nl/*.nl.v
#                          (post-route tile netlists) on sg13g2 cell models,
#                          with the cells' specify delays (-gspecify)
# Not simulated: wire parasitics (no SDF) - this is a FUNCTIONAL check of the
# post-layout netlist (does the GDS's netlist run the bitstreams correctly?),
# not a timing sign-off. Clock: 25 MHz (#20), well below the measured
# worst-case post-layout Fmax of every design here.
#
# X handling: a hardened fabric powers up all-X and gate-level muxes are
# X-pessimistic. Once, at config_done after the first upload:
#   force_block.vh       (FABulous gen_gl_xinit.py) - 0 on still-X inter-tile
#                        nets, async-reset pulse on still-X flops
#   force_block_tiles.vh (sim/gl_xscrub_tiles.py, only with GL_SCRUB=full)
#                        - 0 on still-X tile-INTERNAL wires: breaks X loops in
#                        unused switch-matrix paths FABulous' block cannot reach.
#                        Caveat: on a yosys-synthesised mock netlist this woke
#                        zero-delay loops and stalled the simulator at the scrub
#                        instant; try the default first. A run that exceeds
#                        TIMEOUT is reported as TIMEOUT, not as a pass/fail.
# Both are X-only: they add definedness where the design left X, never
# overwrite a configured value - a wrong configuration still mismatches.
#
# Expectations: blocks14p / blk_* from build/bitstreams/<d>.expect (golden RTL
# sim, silicon-confirmed on Versal); counter14 / lfsr14 from the same built-in
# models sw/efpga.py checks silicon against.
# -----------------------------------------------------------------------------
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
FAB="$HERE/fabric"
OUT="$HERE/build/gl"
mkdir -p "$OUT"
DESIGNS=("$@")
[[ ${#DESIGNS[@]} -gt 0 ]] || DESIGNS=(counter14 lfsr14 blocks14p)

# --- inputs present? -----------------------------------------------------------
NL="${NLROOT:-$FAB}"   # netlist root override (testing)
FABNL=$(ls "$NL"/Fabric/macro/final_views/nl/*.nl.v 2>/dev/null | head -1 || true)
[[ -n "$FABNL" ]] || { echo "no fabric netlist - run gen_fabric_macro first"; exit 1; }
mapfile -t TILENL < <(ls "$NL"/Tile/*/macro/final_views/nl/*.nl.v 2>/dev/null)
[[ ${#TILENL[@]} -gt 0 ]] || { echo "no tile netlists - run gen_all_tile_macros first"; exit 1; }
if [[ -z "${CELLS:-}" ]]; then
    for c in "$HOME/.ciel/ihp-sg13g2/ihp-sg13g2/libs.ref/sg13g2_stdcell/verilog/sg13g2_stdcell.v" \
             "${FAB_PDK_ROOT:-/nonexistent}/ihp-sg13g2/libs.ref/sg13g2_stdcell/verilog/sg13g2_stdcell.v"; do
        [[ -f "$c" ]] && CELLS="$c" && break
    done
fi
[[ -f "${CELLS:-}" ]] || { echo "sg13g2_stdcell.v not found - set CELLS=/path/to/sg13g2_stdcell.v"; exit 1; }
echo "fabric netlist : $FABNL"
echo "tile netlists  : ${#TILENL[@]}"
echo "cell models    : $CELLS"

# --- behavioural wrapper (same sources as the Vivado/RTL flows) ---------------
"$HERE/scripts/prepare_sources.sh" >/dev/null
WRAP=()
for f in "$FAB"/Fabric/*.v; do
    b=$(basename "$f")
    case "$b" in eFPGA.v|models_pack.v) continue ;; esac
    WRAP+=("$HERE/build/src/fabric/$b")
done
WRAP+=("$HERE/build/src/fabric/sram_1rw1r_32_256_8_sky130_fpga.v")

# --- X-scrub block -----------------------------------------------------------
python3 "$FAB/Test/gen_gl_xinit.py" --efpga "$FABNL" --tile-dir "$NL/Tile" \
    --pdk ihp-sg13g2 --top-inst dut.eFPGA_inst --trigger config_done \
    --out "$OUT/force_block.vh"
if [[ "${GL_SCRUB:-fabulous}" == "full" ]]; then
    python3 "$HERE/sim/gl_xscrub_tiles.py" --efpga "$FABNL" --tile-dir "$NL/Tile" \
        --top-inst dut.eFPGA_inst --trigger config_done --out "$OUT/force_block_tiles.vh"
else
    echo "// GL_SCRUB=fabulous: tile-internal scrub disabled" > "$OUT/force_block_tiles.vh"
fi

# --- expectations for the built-in designs ------------------------------------
for d in "${DESIGNS[@]}"; do
    case "$d" in counter14|lfsr14)
        python3 - "$d" > "$OUT/$d.expect" <<'EOF'
import sys
d = sys.argv[1]
def model(n):  # identical to sw/efpga.py builtin_expect (silicon-checked)
    if d == "counter14":
        return n & 0x3FFF
    s = 1
    for _ in range(n):
        fb = ((s >> 13) ^ (s >> 12) ^ (s >> 11) ^ (s >> 1)) & 1
        s = ((s << 1) | fb) & 0x3FFF
    return s
for n in (1, 2, 3, 37, 1000, 16383):
    print(n, "%04x" % model(n))
EOF
        ;;
    *)  cp "$HERE/build/bitstreams/$d.expect" "$OUT/$d.expect" ;;
    esac
done

# --- compile once --------------------------------------------------------------
echo '+timescale+1ns/1ps' > "$OUT/timescale.f"
echo "== compiling gate-level testbench (this takes a while)"
iverilog -g2012 -gspecify -DGL_SIM -f "$OUT/timescale.f" -I "$OUT" \
    -s tb_fabric_expect -o "$OUT/tb_expect_gl.vvp" \
    "${WRAP[@]}" "$FABNL" "${TILENL[@]}" "$CELLS" "$HERE/sim/tb_fabric_expect.v" \
    2>&1 | grep -Eiv "warning|timescale|inherit|redefin|implicit|sorry: .*specify" | head -40 || true
[[ -f "$OUT/tb_expect_gl.vvp" ]] || { echo "compile failed"; exit 1; }

# --- run -------------------------------------------------------------------------
fail=0
for d in "${DESIGNS[@]}"; do
    echo "== $d (gate level)"
    args=(+hex="$HERE/build/bitstreams/$d.hex" +expect="$OUT/$d.expect")
    [[ -n "${MAXN:-}" ]] && args+=(+maxn="$MAXN")
    start=$(date +%s)
    rc=0
    timeout "${TIMEOUT:-3600}" vvp -n "$OUT/tb_expect_gl.vvp" "${args[@]}" > "$OUT/$d.log" 2>&1 || rc=$?
    grep -E "n=|RESULT|checking|design |scrub" "$OUT/$d.log" || true
    [[ $rc -eq 124 ]] && echo "   TIMEOUT after ${TIMEOUT:-3600} s (simulator stalled or too slow)"
    echo "   ($(( $(date +%s) - start )) s)"
    grep -q "RESULT: PASS" "$OUT/$d.log" || fail=1
done
[[ $fail -eq 0 ]] && echo "GATE-LEVEL: PASS" || { echo "GATE-LEVEL: FAIL"; exit 1; }
