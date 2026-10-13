#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# drt_probe.sh : re-run only detailed routing of a FABulous tile run, without
#                FABulous' 900 s kill, and keep the DRC report.
#
#   scripts/drt_probe.sh <tile run dir> [out dir]
#   e.g. scripts/drt_probe.sh fabric/Tile/DSP/macro/fabric_optimised/runs/RUN_x
#
# Why: FABulous.DetailedRoutingTimed kills OpenROAD after FABULOUS_DRT_TIMEOUT
# (900 s) and nothing is written - no DRC report, so a tile that stalls at
# "N violations" cannot be diagnosed. This takes the odb that went INTO detailed
# routing (last step before it), routes with the same layers/iterations from
# the step's config.json, writes a DRC report every 5 iterations and a final
# one, then summarises the remaining violations by type/layer/source nets.
# Answers: does it converge given time (-> raise the timeout), or is it stuck
# on a fixed geometry (-> which nets/objects, where)?
# -----------------------------------------------------------------------------
set -euo pipefail
RUN=${1:?usage: drt_probe.sh <tile run dir> [out dir]}
OUT=${2:-build/drt_probe}
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)

# config of the routing step (any step's config.json has the same RT_* values)
CFG=$(find "$RUN" -name config.json -path '*detailedrout*' -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2)
[[ -n "$CFG" ]] || CFG=$(find "$RUN" -name config.json -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2)
# odb fed to detailed routing = newest odb written before the routing step
ODB=$(find "$RUN" -name '*.odb' -not -path '*detailedrout*' -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2)
# guides: the odb normally carries them (GRT + incremental GRT after diode
# insertion); an old .guide file would miss the diode nets. NO_GUIDE=0 forces it.
GUIDE=""
[[ "${NO_GUIDE:-1}" == 0 ]] && GUIDE=$(find "$RUN" -name '*.guide' -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2 || true)
read -r MINL MAXL ITERS < <(python3 - "$CFG" <<'EOF'
import json, sys
c = json.load(open(sys.argv[1]))
print(c.get("RT_MIN_LAYER") or "Metal2", c.get("RT_MAX_LAYER") or "TopMetal1", c.get("DRT_OPT_ITERS") or 64)
EOF
)
echo "config : $CFG"
echo "odb    : $ODB"
echo "guide  : ${GUIDE:-<none, using guides stored in odb>}"
echo "layers : $MINL..$MAXL  iterations: $ITERS  out: $OUT"

cat > "$OUT/drt.tcl" <<EOF
read_db {$ODB}
$( [[ -n "${GUIDE:-}" ]] && echo "read_guides {$GUIDE}" )
set_thread_count [exec nproc]
# OpenROAD master: -bottom/-top_routing_layer of detailed_route are gone (DRT-0509)
set_routing_layers -signal $MINL-$MAXL
detailed_route -droute_end_iter $ITERS -drc_report_iter_step 5 \\
    -output_drc {$OUT/drt.rpt} -verbose 1
write_db {$OUT/drt.odb}
EOF
start=$(date +%s)
openroad -exit "$OUT/drt.tcl" > "$OUT/drt.log" 2>&1 || echo "openroad rc=$? (see $OUT/drt.log)"
echo "elapsed $(( $(date +%s) - start )) s"
echo "violations per iteration: $(grep -E 'DRT-0199' "$OUT/drt.log" | awk '{print $NF}' | tr -d '.' | tr '\n' ' ')"

# summary of the last report (final, or the latest per-iteration one)
RPT=$(ls -t "$OUT"/drt*rpt* 2>/dev/null | head -1 || true)
[[ -n "$RPT" ]] || { echo "no DRC report written"; exit 0; }
echo "report : $RPT"
python3 - "$RPT" <<'EOF'
import collections, re, sys
txt = open(sys.argv[1]).read()
items = re.findall(r"violation type: (\S+)\s+srcs: ([^\n]*)\n(?:.*\n)*?\s*bbox = \(\s*([\d.]+),\s*([\d.]+)\s*\)\s*-\s*\(\s*([\d.]+),\s*([\d.]+)\s*\)\s*on Layer (\S+)", txt)
print(f"{len(items)} violations")
by = collections.Counter((t, l) for t, *_, l in items)
for (t, l), n in by.most_common():
    print(f"  {n:4d}  {t} on {l}")
srcs = collections.Counter()
for t, s, *_ in items:
    for x in s.split():
        srcs[x] += 1
print("most frequent sources (net:/obs:/pin: names):")
for s, n in srcs.most_common(15):
    print(f"  {n:4d}  {s}")
print("locations (um):")
for t, s, x0, y0, x1, y1, l in items[:25]:
    print(f"  {t:8s} {l:7s} ({x0},{y0})-({x1},{y1})  {s}")
EOF
