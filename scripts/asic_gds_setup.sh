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
# Tools needed by the LibreLane flow (pip install, no nix):
#   verilator, klayout, magic : sudo apt install -y verilator klayout magic
#   netgen (LVS)              : git clone https://github.com/RTimothyEdwards/netgen
#                               cd netgen && ./configure && make -j && sudo make install
#   pyosys (python yosys)     : pip install pyosys     (inside the venv)
#   openroad                  : prebuilt .deb from
#                               https://github.com/Precision-Innovations/OpenROAD/releases
#                               pick openroad_*_amd64-ubuntu-$(lsb_release -rs).deb
#                               sudo apt install ./openroad_*.deb
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
need klayout   "sudo apt install -y klayout"
need magic     "sudo apt install -y magic"
need netgen    "build from github.com/RTimothyEdwards/netgen (see header)"
need openroad  "prebuilt .deb from github.com/Precision-Innovations/OpenROAD/releases (see header)"

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
echo
echo "Ready. Re-source env.sh, then:"
echo "  cd $HERE/fabric"
echo "  FABulous -p . run \"load_fabric; gen_tile_macro LUT4AB\""
