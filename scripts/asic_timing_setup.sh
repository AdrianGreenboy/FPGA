#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# asic_timing_setup.sh : prepare the FABulous *structural* timing-model flow
#                        for the IHP SG13G2 PDK (130 nm).
#
#   usage: scripts/asic_timing_setup.sh <ihp-open-pdk-dir> [typ|slow]
#
#   <ihp-open-pdk-dir> : checkout of https://github.com/IHP-GmbH/IHP-Open-PDK
#                        (only ihp-sg13g2/libs.ref/sg13g2_stdcell/lib is needed:
#                        git clone --depth 1 --filter=blob:none --sparse <url>
#                        git sparse-checkout set ihp-sg13g2/libs.ref/sg13g2_stdcell/lib)
#   corner             : typ  = 1.20 V, 25 C   (default)
#                        slow = 1.08 V, 125 C  (worst case)
#
# What it does (idempotent):
#   1. Checks for a NATIVE yosys (yowasp-yosys does not support `yosys -C`,
#      which the timing flow needs) and for OpenSTA (`sta`) - build notes below.
#   2. Patches two upstream bugs in the installed python packages:
#        a. sdf_timing lexer rejects '$' in escaped instance names, which the
#           SG13G2-mapped netlists contain (e.g. LUT_flop$_DFFE_PP_).
#        b. fabulous timing tools crash while REPORTING a failed subprocess
#           (str.join over PosixPath), masking the real error.
#   3. Sets the measured SG13G2 bel delays in gen_npnr_model.py so bel.v3.txt /
#      placement_estimate.txt match the corner (values measured with OpenSTA on
#      the yosys-mapped LUT4c_frame_config_dffesr bel, see README).
#   4. Writes fabric/timing_cfg.json for `timing_model --with-config-file`.
#
# After it runs:
#   cd fabric
#   FABulous -p . run "load_fabric; gen_model_npnr"
#   FABulous -p . run "load_fabric; timing_model --mode structural --with-config-file timing_cfg.json"
#   FABulous -p . run "load_fabric; place_and_route user_design/<design>.json"
#   grep "Max frequency" user_design/<design>_npnr_log.txt | tail -1
# (order matters: gen_model_npnr regenerates pips.txt with dummy delays, the
#  timing_model call then overwrites it with the real ones)
#
# Tool builds (once):
#   OpenSTA : needs CUDD. git clone https://github.com/ivmai/cudd &&
#             autoreconf -i && ./configure && make && sudo make install, then
#             git clone https://github.com/parallaxsw/OpenSTA && cmake -B build
#             -DCMAKE_BUILD_TYPE=Release -DCUDD_DIR=/usr/local && make -C build,
#             copy build/sta into the venv bin/.
#   yosys   : git clone --branch v0.66 --recurse-submodules
#             https://github.com/YosysHQ/yosys && make config-gcc && make -j.
#             Do NOT replace the venv's yowasp yosys (the compile flow uses it);
#             point NATIVE_YOSYS at the built binary instead.
# -----------------------------------------------------------------------------
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PDK="${1:?usage: asic_timing_setup.sh <ihp-open-pdk-dir> [typ|slow]}"
CORNER="${2:-typ}"

case "$CORNER" in
    typ)  LIBNAME=sg13g2_stdcell_typ_1p20V_25C.lib
          LUT=0.72; CICO=0.09; CARRYI=0.23; SETUP=0.74; HOLD=0.05; CLK2Q=0.26
          IOS=0.35; IOC2O=0.35; BASE=0.35 ;;
    slow) LIBNAME=sg13g2_stdcell_slow_1p08V_125C.lib
          LUT=1.14; CICO=0.13; CARRYI=0.36; SETUP=1.37; HOLD=0.08; CLK2Q=0.41
          IOS=0.60; IOC2O=0.60; BASE=0.55 ;;
    *) echo "corner must be typ or slow"; exit 1 ;;
esac
LIB="$PDK/ihp-sg13g2/libs.ref/sg13g2_stdcell/lib/$LIBNAME"
[[ -f "$LIB" ]] || { echo "liberty not found: $LIB"; exit 1; }

NATIVE_YOSYS="${NATIVE_YOSYS:-}"
if [[ -z "$NATIVE_YOSYS" ]]; then
    for cand in "$HOME/FPGA/tools/yosys/yosys" "$HOME/tools/yosys066/yosys"; do
        [[ -x "$cand" ]] && NATIVE_YOSYS="$cand" && break
    done
fi
[[ -n "$NATIVE_YOSYS" && -x "$NATIVE_YOSYS" ]] || {
    echo "Native yosys not found. Build yosys v0.66 from source (see header)"
    echo "and set NATIVE_YOSYS=/path/to/yosys - the venv's yowasp wrapper"
    echo "cannot run the timing flow (no 'yosys -C' support)."; exit 1; }
"$NATIVE_YOSYS" --version | grep -q "Yosys 0.66" || \
    echo "WARNING: $NATIVE_YOSYS is not 0.66 - delays may still be fine, prims may differ"

STA="$(command -v sta || true)"
[[ -n "$STA" ]] || { echo "OpenSTA ('sta') not on PATH - build it (see header)"; exit 1; }

PY="$(command -v python3)"
"$PY" -c "import fabulous, sdf_timing" 2>/dev/null || {
    echo "python3 cannot import fabulous - activate the FABulous venv first"; exit 1; }
SITE="$("$PY" - <<'EOF'
import fabulous, sdf_timing, pathlib
print(pathlib.Path(fabulous.__file__).parent)
print(pathlib.Path(sdf_timing.__file__).parent)
EOF
)"
FABPKG="$(echo "$SITE" | sed -n 1p)"
SDFPKG="$(echo "$SITE" | sed -n 2p)"

# --- patch 2a: sdf_timing lexer must accept '$' in identifiers ----------------
LEX="$SDFPKG/sdflex.py"
if ! grep -q 'a-zA-Z0-9_\\/\.\$' "$LEX"; then
    "$PY" - "$LEX" <<'EOF'
import sys
p = sys.argv[1]; s = open(p).read()
old = r"r'[a-zA-Z0-9_\/.\[\]\\]+'"
new = r"r'[a-zA-Z0-9_\/.$\[\]\\]+'"
assert old in s, "sdflex.py STRING rule not found - upstream changed, patch by hand"
open(p, "w").write(s.replace(old, new, 1))
EOF
    find "$SDFPKG" -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
    echo "patched: sdf_timing lexer ('$' in instance names)"
fi

# --- patch 2b: don't crash while reporting a failed subprocess ---------------
for f in "$FABPKG/fabric_cad/timing_model/tools/synth_tools/yosys.py" \
         "$FABPKG/fabric_cad/timing_model/tools/sta_tools/opensta.py"; do
    if grep -q "' '.join(\[executable, \*args\])" "$f"; then
        sed -i "s/' '.join(\[executable, \*args\])/' '.join(map(str, [executable, *args]))/; s/' '.join(args)/' '.join(map(str, args))/" "$f"
        echo "patched: $(basename "$f") (Path join in error reporting)"
    fi
done

# --- 3: measured SG13G2 bel delays into gen_npnr_model.py --------------------
"$PY" - "$FABPKG/fabric_cad/gen_npnr_model.py" \
    "$LUT" "$CICO" "$CARRYI" "$SETUP" "$HOLD" "$CLK2Q" "$IOS" "$IOC2O" "$BASE" <<'EOF'
import re, sys
p = sys.argv[1]
lut, cico, carryi, setup, hold, clk2q, ios, ioc2o, base = sys.argv[2:11]
vals = {
    "LUT_DELAY": lut, "CARRY_CICO_DELAY": cico, "CARRY_I_DELAY": carryi,
    "FF_SETUP": setup, "FF_HOLD": hold, "FF_CLK_TO_Q": clk2q,
    "IO_SETUP": ios, "IO_HOLD": hold, "IO_CLK_TO_OUT": ioc2o,
    "BASE_DELAY_DEFAULT": base, "PIP_DELAY_SCALE": "1.0",
    "DELAY_EPSILON": "0.05", "RIPUP_PENALTY": "0.2", "CARRY_PREDICT_DELAY": "0.1",
}
s = open(p).read()
for k, v in vals.items():
    s, n = re.subn(rf"^{k} = [0-9.]+$", f"{k} = {v}", s, flags=re.M)
    if n != 1:
        sys.exit(f"gen_npnr_model.py: constant {k} not found exactly once")
open(p, "w").write(s)
print("patched: gen_npnr_model.py bel delays ->", ", ".join(f"{k}={v}" for k, v in vals.items()))
EOF
find "$FABPKG" -name "__pycache__" -path "*fabric_cad*" -exec rm -rf {} + 2>/dev/null || true

# --- 4: timing_cfg.json ------------------------------------------------------
cat > "$HERE/fabric/timing_cfg.json" <<JSON
{
  "project_dir": "$HERE/fabric",
  "liberty_files": ["$LIB"],
  "min_buf_cell_and_ports": "sg13g2_buf_1 A X",
  "synth_executable": "$NATIVE_YOSYS",
  "sta_executable": "$STA",
  "pdk_name": "ihp-sg13g2",
  "techmap_files": ["$HERE/fabric/Tile/include/sg13g2_latchmap.v"],
  "tiehi_cell_and_port": "sg13g2_tiehi L_HI",
  "tielo_cell_and_port": "sg13g2_tielo L_LO",
  "mode": "structural"
}
JSON
echo "wrote fabric/timing_cfg.json (corner: $CORNER, liberty: $LIBNAME)"
echo
echo "next:"
echo "  cd $HERE/fabric"
echo "  FABulous -p . run \"load_fabric; gen_model_npnr\""
echo "  FABulous -p . run \"load_fabric; timing_model --mode structural --with-config-file timing_cfg.json\""
echo "  FABulous -p . run \"load_fabric; place_and_route user_design/counter14.json\""
echo "  grep 'Max frequency' user_design/counter14_npnr_log.txt | tail -1"
