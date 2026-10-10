#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# asic_gds_setup.sh : prepare the FABulous -> LibreLane GDS hardening flow
#                     (IHP SG13G2) on a machine with normal internet access.
#
#   usage: scripts/asic_gds_setup.sh        (run from the repo, venv active)
#
# Installs nothing by itself - it CHECKS every tool the flow needs, tells you
# the one-liner for whatever is missing, and configures the project when all
# checks pass. Safe to re-run until it is happy.
#
# Tools needed by the LibreLane flow (pip install, no nix). Validated
# 2026-10-10 on Ubuntu 24.04 - the apt versions of magic/klayout/netgen are
# TOO OLD for the IHP PDK decks, and openroad must have Python support:
#   verilator          : sudo apt install -y verilator
#   Tcl/Tk headers     : sudo apt install -y tcl-dev tk-dev libcairo2-dev \
#                          libx11-dev libglu1-mesa-dev m4 csh
#                        (install BEFORE building magic/netgen: without tcl-dev
#                        netgen builds a non-Tcl variant lacking '-batch')
#   magic  (>= 8.3.5xx): git clone https://github.com/RTimothyEdwards/magic
#                        ./configure && make -j && sudo make install
#   netgen (Tcl build) : git clone https://github.com/RTimothyEdwards/netgen
#                        ./configure && make -j && sudo make install
#   klayout (>= 0.29)  : official .deb from https://www.klayout.de/build.html
#                        (Ubuntu-24), sudo apt install ./klayout_*.deb
#                        apt's 0.28 fails the IHP DRC deck ('absolute').
#   pyosys             : pip install pyosys     (inside the venv)
#   openroad (+python) : no .deb for 24.04. Build from source, CMake variant
#                        (the default Bazel build has NO '-python', which
#                        LibreLane's Odb steps require):
#                          git clone --recursive https://github.com/The-OpenROAD-Project/OpenROAD
#                          sudo ./etc/DependencyInstaller.sh -all
#                          ./etc/Build.sh -cmake-build -threads=$(nproc)
#                          sudo ln -sf $PWD/build/bin/openroad /usr/local/bin/openroad
#                        Put ~/.bazelrc 'startup --output_user_root=<big disk>'
#                        if you ever use the Bazel build (cache is huge).
#
# OpenROAD master vs LibreLane 3.0.16 / FABulous 2.2 - three incompatibilities,
# all handled by this script + fabric/Tile/*/gds_config.yaml:
#   1. CTS macro/register latency balancing explodes on tiles (30k delay
#      buffers, OpenROAD dies): cts.tcl gets '-no_insertion_delay' via
#      CTS_NO_INSERTION_DELAY=1 (patched below, exported from env.sh).
#   2. dbTechLayer::getArea() now returns DBU^2 -> FABulous pin-length fallback
#      makes 360 mm pins (GRT-0080): IO_PIN_{V,H}_LENGTH fixed to 0.36 um.
#   3. Port diodes on UserCLKo confuse CTS: DIODE_ON_PORTS none for IHP
#      (antenna repair after GRT still protects the ports).
# openroad -python runs an embedded interpreter that does not see the venv:
# PYTHONPATH=<venv site-packages> is exported from env.sh.
#
# PDK: FAB_PDK=ihp-sg13g2 in fabric/.FABulous/.env is enough - FABulous resolves
# the recommended hash from librelane and ciel downloads the PDK (~1 GB) to
# ~/.ciel on first use. Do NOT set FAB_PDK_ROOT unless you manage the PDK
# yourself.
#
# yosys: LibreLane's synthesis steps invoke `yosys -y` (python-enabled yosys).
# Neither the venv's yowasp wrapper nor a stock source build supports that, so
# scripts/yosys-pyosys shims it onto the pyosys pip wheel. The shim is picked
# up through the _LLN_OVERRIDE_YOSYS environment variable, which this script
# adds to env.sh (FABulous rejects unknown keys in .FABulous/.env, so it must
# be a real exported variable).
#
# After setup, the flow (times are per-run, multicore helps a lot):
#   cd fabric
#   FABulous -p . run "load_fabric; gen_tile_macro LUT4AB"       # first, alone
#   FABulous -p . run "load_fabric; gen_all_tile_macros"         # the rest
#   FABulous -p . run "load_fabric; gen_fabric_macro"            # stitching
# Results: Tile/<T>/macro/final_views/{gds,lef,nl,spef}, Fabric/macro/, gds/.
# Then the physical timing model closes the loop:
#   FABulous -p . run "load_fabric; timing_model --mode physical"
# -----------------------------------------------------------------------------
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
missing=0
need() {
    if command -v "$1" >/dev/null 2>&1; then
        echo "  ok: $1 ($(command -v "$1"))"
    else
        echo "  MISSING: $1 - $2"
        missing=1
    fi
}
echo "== tool checks"
need verilator "sudo apt install -y verilator"
need klayout   "official .deb from klayout.de (see header)"
need magic     "build from github.com/RTimothyEdwards/magic (see header)"
need netgen    "build from github.com/RTimothyEdwards/netgen AFTER tcl-dev (see header)"
need openroad  "CMake source build with Python (see header)"

if command -v openroad >/dev/null 2>&1 && ! openroad -help 2>&1 | grep -q -- "-python"; then
    echo "  BAD: openroad has no -python (Bazel build?) - rebuild with -cmake-build"; missing=1
fi
if command -v klayout >/dev/null 2>&1; then
    kv=$(klayout -v 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
    case "$kv" in 0.2[0-8]|0.1*) echo "  BAD: klayout $kv too old (need >= 0.29)"; missing=1 ;; esac
fi
if command -v netgen >/dev/null 2>&1 && echo quit | netgen -batch 2>&1 | grep -q "Unrecognized switch"; then
    echo "  BAD: netgen built without Tcl (no -batch) - rebuild after installing tcl-dev"; missing=1
fi

if python3 -c "import pyosys" 2>/dev/null; then
    echo "  ok: pyosys ($(python3 -c 'import pyosys,pathlib;print(pathlib.Path(pyosys.__file__).parent)'))"
else
    echo "  MISSING: pyosys - pip install pyosys (venv active)"; missing=1
fi
python3 -c "import fabulous" 2>/dev/null || { echo "  MISSING: fabulous - activate the venv"; missing=1; }

[[ $missing -eq 0 ]] || { echo; echo "Install the missing tools above and re-run."; exit 1; }

echo "== project config"
ENVF="$HERE/fabric/.FABulous/.env"
grep -q "^FAB_PDK=" "$ENVF" 2>/dev/null || { echo "FAB_PDK=ihp-sg13g2" >> "$ENVF"; echo "  added FAB_PDK=ihp-sg13g2 to .FABulous/.env"; }
grep -q "^FAB_PDK='\?ihp-sg13g2" "$ENVF" || echo "  NOTE: FAB_PDK in $ENVF is not ihp-sg13g2 - edit it if you want IHP"

if [[ -f "$HERE/env.sh" ]] && ! grep -q "_LLN_OVERRIDE_YOSYS" "$HERE/env.sh"; then
    echo "export _LLN_OVERRIDE_YOSYS=\"$HERE/scripts/yosys-pyosys\"" >> "$HERE/env.sh"
    echo "  added _LLN_OVERRIDE_YOSYS export to env.sh (re-source it!)"
fi
chmod +x "$HERE/scripts/yosys-pyosys"

SITE="$(python3 -c 'import sysconfig;print(sysconfig.get_paths()["purelib"])')"
if [[ -f "$HERE/env.sh" ]] && ! grep -q "CTS_NO_INSERTION_DELAY" "$HERE/env.sh"; then
    {
        echo "export PYTHONPATH=\"$SITE\${PYTHONPATH:+:\$PYTHONPATH}\""
        echo "export CTS_NO_INSERTION_DELAY=1"
    } >> "$HERE/env.sh"
    echo "  added PYTHONPATH (openroad -python) + CTS_NO_INSERTION_DELAY to env.sh"
fi

CTS="$SITE/librelane/scripts/openroad/cts.tcl"
if [[ -f "$CTS" ]] && ! grep -q "no_insertion_delay" "$CTS"; then
    cp "$CTS" "$CTS.orig"
    sed -i '/CTS_BALANCE_LEVELS -balance_levels/a\if { [info exists ::env(CTS_NO_INSERTION_DELAY)] \&\& $::env(CTS_NO_INSERTION_DELAY) } { lappend arg_list -no_insertion_delay }' "$CTS"
    grep -q "no_insertion_delay" "$CTS" && echo "  patched librelane cts.tcl (-no_insertion_delay)" \
        || { echo "  FAILED to patch $CTS - upstream changed, patch by hand"; exit 1; }
fi
echo
echo "Ready. Re-source env.sh, then:"
echo "  cd $HERE/fabric"
echo "  FABulous -p . run \"load_fabric; gen_tile_macro LUT4AB\""
