"""top_place_report.py : where did the placer put eFPGA_top's logic, and which
nets are long? (run inside OpenROAD's python)

    openroad -python -exit scripts/top_place_report.py <design.odb>
    (or ODB=<design.odb> openroad -python -exit scripts/top_place_report.py)

Prints, per top-level hierarchy group (eFPGA_Config, Frame_Data_Reg_k,
Frame_Select_k, Inst_BlockRAM_k, ...): cell count, centroid and bounding box;
then half-perimeter wirelength (HPWL) summed per net class and the 20 longest
nets. Used to see whether config logic landed next to the fabric edges it
drives (FrameData -> eFPGA west edge, FrameStrobe -> south edge) or far away.
"""
import collections
import os
import re
import sys

from openroad import Design, Tech

path = os.environ.get("ODB") or (sys.argv[1] if len(sys.argv) > 1 else None)
if not path:
    sys.exit(__doc__)
tech = Tech()
design = Design(tech)
design.readDb(path)
block = design.getBlock()
dbu = block.getDbUnitsPerMicron()
die = block.getDieArea()
print(f"die {die.xMax() / dbu:.0f} x {die.yMax() / dbu:.0f} um, {path}")


def um(v):
    return v / dbu


groups = collections.defaultdict(list)
macros = []
for inst in block.getInsts():
    m = inst.getMaster()
    bb = inst.getBBox()
    if m.isBlock():
        macros.append((inst.getName(), um(bb.xMin()), um(bb.yMin()), um(bb.xMax()), um(bb.yMax())))
        continue
    if m.isFiller() or m.getType() in ("CORE_WELLTAP", "ENDCAP", "CORE_SPACER"):
        continue
    name = inst.getName()
    g = re.split(r"[./]", name.lstrip("\\"))[0] if re.search(r"[./]", name) else "(top-level glue)"
    groups[g].append(((bb.xMin() + bb.xMax()) / 2, (bb.yMin() + bb.yMax()) / 2))

print("\nmacros:")
for n, x1, y1, x2, y2 in macros:
    print(f"  {n:42s} ({x1:7.1f},{y1:7.1f})-({x2:7.1f},{y2:7.1f})")
# region histogram of all std cells (flattened yosys names carry no hierarchy)
ex1 = ey1 = ex2 = ey2 = None
for n, x1, y1, x2, y2 in macros:
    if n == "eFPGA_inst":
        ex1, ey1, ex2, ey2 = x1, y1, x2, y2
if ex1 is not None:
    reg = collections.Counter()
    for pts in groups.values():
        for x, y in pts:
            x, y = um(x), um(y)
            if x > ex2:
                reg["east (gap + SRAM column)"] += 1
            elif x < ex1:
                reg["west strip"] += 1
            elif y < ey1:
                reg["south strip"] += 1
            else:
                reg["north strip"] += 1
    print("\nstd cells per region:", dict(reg.most_common()))
    east = collections.Counter()
    for pts in groups.values():
        for x, y in pts:
            if um(x) > ex2:
                east[int(um(y) // 100) * 100] += 1
    print("  east cells per 100 um of y:", dict(sorted(east.items())))

print("\nstd cells per group: count  centroid  bbox")
for g, pts in sorted(groups.items(), key=lambda kv: -len(kv[1])):
    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
    print(f"  {g:30s} {len(pts):6d}  ({um(sum(xs) / len(xs)):7.1f},{um(sum(ys) / len(ys)):7.1f})"
          f"  x {um(min(xs)):7.1f}..{um(max(xs)):7.1f}  y {um(min(ys)):7.1f}..{um(max(ys)):7.1f}")


def pin_xy(it):
    try:
        b = it.getBBox()
        return (b.xMin() + b.xMax()) / 2, (b.yMin() + b.yMax()) / 2
    except Exception:
        b = it.getInst().getBBox()
        return (b.xMin() + b.xMax()) / 2, (b.yMin() + b.yMax()) / 2


def classify(net):
    for it in net.getITerms():
        n = it.getMTerm().getName()
        i = it.getInst().getName()
        if i == "eFPGA_inst":
            if n.startswith("FrameData"):
                return "FrameData -> eFPGA"
            if n.startswith("FrameStrobe"):
                return "FrameStrobe -> eFPGA"
            if "RAM" in n:
                return "RAM <-> eFPGA"
            return "other eFPGA pin"
        if "u_sram" in i:
            return "SRAM pin"
    if net.getBTerms():
        return "top IO"
    return "internal"


per_class = collections.Counter()
per_class_n = collections.Counter()
longest = []
for net in block.getNets():
    if net.isSpecial() or net.getSigType() in ("POWER", "GROUND"):
        continue
    pts = [pin_xy(it) for it in net.getITerms()]
    for bt in net.getBTerms():
        for bp in bt.getBPins():  # dbBTerm.getBBox() is not reliable here
            for b in bp.getBoxes():
                pts.append(((b.xMin() + b.xMax()) / 2, (b.yMin() + b.yMax()) / 2))
    if len(pts) < 2:
        continue
    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
    hp = um(max(xs) - min(xs) + max(ys) - min(ys))
    c = classify(net)
    per_class[c] += hp
    per_class_n[c] += 1
    longest.append((hp, net.getName(), c, len(pts)))

print("\nHPWL per net class (lower bound of routed length):")
tot = sum(per_class.values())
for c, v in per_class.most_common():
    print(f"  {c:24s} {per_class_n[c]:6d} nets  {v / 1000:9.1f} mm  ({v / tot * 100:4.1f} %)")
print(f"  {'TOTAL':24s} {sum(per_class_n.values()):6d} nets  {tot / 1000:9.1f} mm")
print("\n20 longest nets (HPWL um, class, pins):")
for hp, n, c, k in sorted(longest, reverse=True)[:20]:
    print(f"  {hp:8.0f}  {n:50s} {c:22s} {k}")
