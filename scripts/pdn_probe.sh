#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# pdn_probe.sh : run the eFPGA_top flow only up to GeneratePDN in a few PDN
#                variants, to isolate why pdngen cannot repair channels.
#
#   scripts/pdn_probe.sh            (after scripts/gen_top_config.py)
#
# Variants (each a copy of build/top/config.yaml with one change):
#   base     : as generated
#   skiptrim : PDN_SKIPTRIM true          -> is metal trimming removing straps?
#   nosram   : default PDN_CFG (no SRAM grid) -> does the SRAM grid reserve
#              TopMetal1 over the SRAM+halo and starve the rows next to it?
#   halo0    : PDN halos 0 (rows are still cut at 10 um by FP_MACRO_*_HALO)
# Prints per variant: PDN-0178 channel count, PDN-0179/0233 errors, and
# whether the SRAM pins got connected (check_power_grid reports).
# -----------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TOP="$HERE/build/top"
[[ -f "$TOP/config.yaml" ]] || { echo "run scripts/gen_top_config.py first"; exit 1; }
cd "$TOP"

variant() {  # variant <name> <sed expression | ''> [append-line]
    local n=$1 expr=$2 extra=${3:-}
    cp config.yaml "probe_$n.yaml"
    [[ -n "$expr" ]] && sed -i "$expr" "probe_$n.yaml"
    [[ -n "$extra" ]] && printf '%s\n' "$extra" >> "probe_$n.yaml"
}
variant base     ''
variant skiptrim '' 'PDN_SKIPTRIM: true'
variant nosram   '/^PDN_CFG:/d'
variant halo0    '' $'PDN_HORIZONTAL_HALO: 0\nPDN_VERTICAL_HALO: 0'

for n in base skiptrim nosram halo0; do
    log="probe_$n.log"
    librelane --pdk ihp-sg13g2 --run-tag "probe_$n" --overwrite \
        --to OpenROAD.GeneratePDN "probe_$n.yaml" > "$log" 2>&1
    ch=$(grep -c "PDN-0178" "$log")
    err=$(grep -oE "PDN-0(179|233|232)[^.]*" "$log" | sort -u | tr '\n' ' ')
    sdir=$(ls -d runs/probe_$n/*-openroad-generatepdn 2>/dev/null | tail -1)
    grid=""
    if [[ -n "$sdir" ]]; then
        for r in "$sdir"/*-grid-errors.rpt; do
            [[ -f "$r" ]] && grid+="$(basename "$r" -grid-errors.rpt):$(grep -c . "$r") "
        done
    fi
    printf "%-9s channels=%-3s %s %s\n" "$n" "$ch" "${err:-PDN ok}" "${grid:+grid-error-lines: $grid}"
done
