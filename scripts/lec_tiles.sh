#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# lec_tiles.sh : formal equivalence check (yosys equiv_*) of every hardened tile
#                netlist against its RTL - for ALL configurations, not just the
#                bitstreams a simulation happens to load.
#
#   scripts/lec_tiles.sh [tile ...]        default: every tile with a netlist
#   JOBS=8 scripts/lec_tiles.sh            parallel tiles (default: nproc/2)
#   LIB=/path/sg13g2_stdcell_typ_1p20V_25C.lib   liberty override
#   NLROOT=/other/fabric                   netlist tree override (testing)
#   YOSYS=/path/to/yosys                   default $NATIVE_YOSYS, else yosys
#   LEC_GOLD=synth                         gold = LibreLane's own synthesised
#                                          netlist (pre-PnR) instead of the RTL
#   LEC_TIMEOUT=1800                       per-tile limit (s), reported TIMEOUT
#
# gold : RTL tile (fabric/Tile/<T>/**.v + Fabric/models_pack.v), proc+memory+flatten
# gate : Tile/<T>/macro/final_views/nl/<T>.nl.v on the sg13g2 cell FUNCTIONS
#        (read_liberty without -lib: ff/latch/combinational groups -> yosys cells;
#        fill/decap/tap/antenna cells have no function and drop out)
# check: equiv_make (matched by name: ports + surviving state-element nets),
#        async2sync, equiv_simple -seq 2, equiv_induct -seq 2, equiv_status.
#
# Verification chain this closes: RTL (silicon-validated on Versal)
#   == post-route netlist (this script) == layout (Netgen LVS) == GDS.
#
# Two-step proof for arithmetic tiles: equiv_simple cannot close the DSP's
# 8x8 multiplier cone RTL-vs-gates in reasonable time (abc restructures it
# completely; on a yosys mock the MULADD alone ran > 10 min). For DSP use
# LEC_GOLD=synth: post-route == LibreLane synthesis is structurally close
# (PnR only buffers/resizes/repairs) and proves fast. RTL == synthesis for the
# multiplier is then yosys' own synthesis correctness - stated, not proven.
#
# Interpretation: "proven" is a proof. "unproven" is NOT automatically a bug:
# if the router renamed state-element nets, equiv_make cannot pair them and the
# induction may be too weak. Unproven points are listed in the log; look at
# them before concluding anything. Method check (2026-10-11, on a yosys-mapped
# LUT4AB): 966/966 proven; swapping two inputs of ONE mux4 -> 104 unproven.
# -----------------------------------------------------------------------------
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
FAB="$HERE/fabric"
NL="${NLROOT:-$FAB}"
OUT="$HERE/build/lec"; mkdir -p "$OUT"
YOSYS="${YOSYS:-${NATIVE_YOSYS:-yosys}}"
command -v "$YOSYS" >/dev/null || [[ -x "$YOSYS" ]] || { echo "yosys not found (set YOSYS=)"; exit 1; }
if [[ -z "${LIB:-}" ]]; then
    for c in "$HOME/.ciel/ihp-sg13g2/ihp-sg13g2/libs.ref/sg13g2_stdcell/lib/sg13g2_stdcell_typ_1p20V_25C.lib" \
             "${FAB_PDK_ROOT:-/nonexistent}/ihp-sg13g2/libs.ref/sg13g2_stdcell/lib/sg13g2_stdcell_typ_1p20V_25C.lib"; do
        [[ -f "$c" ]] && LIB="$c" && break
    done
fi
[[ -f "${LIB:-}" ]] || { echo "sg13g2 liberty not found - set LIB="; exit 1; }

TILES=("$@")
if [[ ${#TILES[@]} -eq 0 ]]; then
    mapfile -t TILES < <(ls "$NL"/Tile/*/macro/final_views/nl/*.nl.v | xargs -n1 basename | sed 's/\.nl\.v$//' | sort)
fi

gen() {  # gen <tile> -> writes $OUT/<tile>.ys
    local T=$1 rtl syn
    {
        if [[ "${LEC_GOLD:-rtl}" == "synth" ]]; then
            syn=$(ls -t "$NL"/Tile/"$T"/macro/*/runs/RUN_*/*-yosys-synthesis/"$T".nl.v 2>/dev/null | head -1)
            [[ -n "$syn" ]] || { echo "# no LibreLane synthesis netlist for $T" ; return 1; }
            echo "# gold: $syn"
            echo "read_liberty -ignore_miss_func $LIB"
            echo "read_verilog $syn"
            echo "hierarchy -top $T"
            echo "flatten; opt_clean"
            echo "rename $T gold"
            echo "design -stash gold"
        else
            rtl=$(find "$FAB/Tile/$T" -name '*.v' -not -path '*/macro/*' | sort)
            echo "read_verilog -sv $FAB/Fabric/models_pack.v"
            for f in $rtl; do echo "read_verilog -sv $f"; done
            echo "hierarchy -top $T"
            echo "proc; memory; flatten; opt_clean"
            echo "rename $T gold"
            echo "design -stash gold"
        fi
        echo "read_liberty -ignore_miss_func $LIB"
        echo "read_verilog $NL/Tile/$T/macro/final_views/nl/$T.nl.v"
        echo "hierarchy -top $T"
        echo "flatten; opt_clean"
        echo "rename $T gate"
        echo "design -stash gate"
        echo "design -copy-from gold -as gold gold"
        echo "design -copy-from gate -as gate gate"
        echo "equiv_make gold gate equiv"
        echo "hierarchy -top equiv"
        echo "async2sync"
        echo "equiv_simple -seq 2"
        echo "equiv_induct -seq 2"
        echo "equiv_status"
    } > "$OUT/$T.ys"
}
run() {  # run <tile>
    local T=$1 s
    gen "$T" > /dev/null || { printf "%-16s ERROR     no synthesis netlist (LEC_GOLD=synth)\n" "$T"; return; }
    local rc=0
    timeout "${LEC_TIMEOUT:-1800}" "$YOSYS" -q -s "$OUT/$T.ys" -l "$OUT/$T.log" >/dev/null 2>&1 || rc=$?
    if [[ $rc -eq 124 ]]; then
        printf "%-16s TIMEOUT   after %ss (see header: arithmetic tiles)\n" "$T" "${LEC_TIMEOUT:-1800}"; return
    fi
    s=$(grep -E "Of those cells .* proven" "$OUT/$T.log" | tail -1 | sed 's/^ *//')
    if grep -q "Equivalence successfully proven" "$OUT/$T.log"; then
        printf "%-16s PROVEN    %s\n" "$T" "$s"
    elif [[ -n "$s" ]]; then
        printf "%-16s UNPROVEN  %s  (see build/lec/%s.log)\n" "$T" "$s" "$T"
    else
        printf "%-16s ERROR     (see build/lec/%s.log)\n" "$T" "$T"
    fi
}
export -f gen run
export FAB NL OUT YOSYS LIB LEC_GOLD LEC_TIMEOUT
echo "LEC: ${#TILES[@]} tiles, gold=${LEC_GOLD:-rtl}, liberty $(basename "$LIB"), yosys $("$YOSYS" -V 2>/dev/null | head -1)"
printf "%s\n" "${TILES[@]}" | xargs -P "${JOBS:-$(( ($(nproc)+1)/2 ))}" -I{} bash -c 'run {}' | tee "$OUT/summary.txt"
if grep -qE "UNPROVEN|ERROR|TIMEOUT" "$OUT/summary.txt"; then echo "LEC: NOT ALL PROVEN"; exit 1; fi
echo "LEC: ALL TILES PROVEN"
