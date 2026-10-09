#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# run_sim.sh : eFPGA regression (iverilog + GHDL)
#   1) tb_fabric_reconfig : raw fabric, SelfWrite port, A -> B -> A
#   2) tb_axil            : efpga_axil.vhd (GHDL --synth -> Verilog) + fabric,
#                           full AXI4-Lite path, isolation, CFG_COUNT, readback
#   3) negative test      : loads lfsr14 where counter14 is expected -> must FAIL
# Prerequisite: scripts/compile_user_design.sh designs/{counter14,lfsr14}.v
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

[[ $status -eq 0 ]] && echo "REGRESSION: PASS" || echo "REGRESSION: FAIL"
exit $status
