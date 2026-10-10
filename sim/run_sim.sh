#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# run_sim.sh : eFPGA regression (iverilog + GHDL)
#   1) tb_fabric_reconfig : raw fabric, SelfWrite port, A -> B -> A
#   2) tb_axil            : efpga_axil.vhd (GHDL --synth -> Verilog) + fabric,
#                           full AXI4-Lite path, isolation, CFG_COUNT, readback
#   3) negative test      : loads lfsr14 where counter14 is expected -> must FAIL
#   4) blocks14 (if compiled): golden RTL sim (MULADD + RegFile + BRAM) writes
#      build/bitstreams/blocks14.expect, mutation check (each block must change
#      the signature), then the bitstream on the fabric must match the golden.
#      The fabric part takes ~15-20 min; QUICK=1 skips it.
# Prerequisite: scripts/compile_user_design.sh designs/{counter14,lfsr14,blocks14}.v
# -----------------------------------------------------------------------------
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
B="$HERE/build/sim"
BS="$HERE/build/bitstreams"
"$HERE/scripts/prepare_sources.sh"
rm -rf "$B"; mkdir -p "$B/neg"
for d in counter14 lfsr14; do
    [[ -f "$BS/$d.hex" ]] || { echo "missing $BS/$d.hex - run scripts/compile_user_design.sh designs/$d.v"; exit 1; }
    cp "$BS/$d.hex" "$B/"
done
cp "$BS/lfsr14.hex" "$B/neg/counter14.hex"; cp "$BS/lfsr14.hex" "$B/neg/lfsr14.hex"

cd "$B"
FILT='warning|timescale|inherit|readmemh'
ghdl -a --std=08 "$HERE/rtl/efpga_axil.vhd"
ghdl --synth --std=08 --out=verilog efpga_axil > efpga_axil_synth.v 2> ghdl_synth.log

iverilog -g2012 -s tb_fabric_reconfig -o tb_fabric.vvp -c "$HERE/build/src/sim.f" "$HERE/sim/tb_fabric_reconfig.v" 2>&1 | grep -Eiv "$FILT" || true
iverilog -g2012 -s tb_axil -o tb_axil.vvp -c "$HERE/build/src/sim.f" efpga_axil_synth.v "$HERE/sim/tb_axil.v" 2>&1 | grep -Eiv "$FILT" || true

status=0
echo "== tb_fabric_reconfig";  vvp -n tb_fabric.vvp | grep -Eiv "$FILT|\\\$finish" | tee fabric.log
grep -q "RESULT: PASS" fabric.log || status=1
echo "== tb_axil";             vvp -n tb_axil.vvp   | grep -Eiv "$FILT|\\\$finish" | tee axil.log
grep -q "RESULT: PASS" axil.log || status=1
echo "== negative test (must FAIL)"
(cd neg && vvp -n ../tb_fabric.vvp > neg.log 2>&1 || true)
if grep -q "RESULT: FAIL" neg/neg.log; then echo "negative test: checker detected the wrong bitstream - OK"
else echo "negative test: checker did NOT detect the wrong bitstream"; status=1; fi

if [[ -f "$BS/blocks14.hex" ]]; then
    # FABulous primitive models (MULADD, RegFile_32x4) as used by synth_fabulous
    # (override with PRIMS=...; otherwise found via any python that has yowasp_yosys)
    if [[ -z "${PRIMS:-}" ]]; then
        for py in python3 python3.13 python3.12; do
            PRIMS=$($py -c 'import yowasp_yosys,os;print(os.path.join(os.path.dirname(yowasp_yosys.__file__),"share","fabulous","prims.v"))' 2>/dev/null) && break
        done
    fi
    [[ -f "$PRIMS" ]] || { echo "prims.v not found ($PRIMS) - yowasp-yosys 0.66 installed?"; exit 1; }
    GOLD_SRC=("$HERE/sim/tb_golden_blocks14.v" "$HERE/designs/blocks14.v" "$PRIMS"
              "$HERE/build/src/fabric/BlockRAM_1KB.v" "$HERE/build/src/fabric/sram_1rw1r_32_256_8_sky130_fpga.v")
    echo "== blocks14 golden (RTL: MULADD + RegFile + BRAM)"
    declare -A sig
    for m in NONE MUT_BRAM MUT_RF MUT_MAC; do
        mkdir -p "golden_$m"
        iverilog -g2012 -D$m -s tb_golden_blocks14 -o "golden_$m/g.vvp" "${GOLD_SRC[@]}" 2>&1 | grep -Eiv "$FILT" || true
        (cd "golden_$m" && vvp -n g.vvp > golden.log)
        sig[$m]=$(tr '\n' ' ' < "golden_$m/blocks14.expect")
    done
    grep -E "blocks14 n=|RESULT" golden_NONE/golden.log | tee golden.log
    grep -q "RESULT: PASS" golden.log || status=1
    for m in MUT_BRAM MUT_RF MUT_MAC; do
        if [[ "${sig[$m]}" == "${sig[NONE]}" ]]; then echo "mutation $m NOT detected"; status=1
        else echo "mutation $m changes the signature - OK"; fi
    done
    cp golden_NONE/blocks14.expect "$BS/blocks14.expect"
    if [[ "${QUICK:-0}" != "1" ]]; then
        echo "== tb_fabric_expect: blocks14 bitstream vs golden (slow)"
        iverilog -g2012 -s tb_fabric_expect -o tb_expect.vvp -c "$HERE/build/src/sim.f" "$HERE/sim/tb_fabric_expect.v" 2>&1 | grep -Eiv "$FILT" || true
        vvp -n tb_expect.vvp +hex="$BS/blocks14.hex" +expect="$BS/blocks14.expect" +other="$BS/lfsr14.hex" \
            | grep -Eiv "$FILT|\\\$finish" | tee expect.log
        grep -q "RESULT: PASS" expect.log || status=1
    fi
fi

[[ $status -eq 0 ]] && echo "REGRESSION: PASS" || echo "REGRESSION: FAIL"
exit $status
