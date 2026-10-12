# drc_marker_cells.py : which (leaf) cells sit under KLayout DRC markers?
#
#   klayout -b -r scripts/drc_marker_cells.py -rd gds=<final.gds> -rd rdb=<drc.lyrdb> [-rd n=300]
#
# For every DRC category, takes up to n markers, finds the deepest cell
# instances overlapping each marker's bounding box and counts their names.
# Tells whether a rule fires inside a std cell master (fill/decap/diode...),
# inside a macro (SRAM/eFPGA) or on top-level routing (no cell -> "<top>").
import collections

import pya

gds = globals().get("gds")
rdbf = globals().get("rdb")
nmax = int(globals().get("n", 300))
if not gds or not rdbf:
    raise SystemExit("usage: klayout -b -r drc_marker_cells.py -rd gds=... -rd rdb=...")

ly = pya.Layout()
ly.read(gds)
top = ly.top_cell()
db = pya.ReportDatabase("")
db.load(rdbf)

per_cat = collections.defaultdict(collections.Counter)
seen = collections.Counter()
# In KLayout "deep" mode (LibreLane's IHP default) markers are reported in the
# cell where the violation lives, in that cell's LOCAL coordinates. So first
# count the report cell of each marker - that usually answers the question.
rcell = collections.defaultdict(collections.Counter)
for item in db.each_item():
    cat = db.category_by_id(item.category_id()).name()
    rcell[cat][db.cell_by_id(item.cell_id()).name()] += 1
print("markers per report cell (deep mode: violation lives in that cell):")
for cat, cnt in rcell.items():
    print(f"== {cat}")
    for name, k in cnt.most_common(8):
        print(f"   {k:6d}  {name}")
print()

for item in db.each_item():
    cat = db.category_by_id(item.category_id()).name()
    if db.cell_by_id(item.cell_id()).name() != top.name:
        continue  # local coordinates of a sub-cell: geometric lookup below is top-only
    if seen[cat] >= nmax:
        continue
    seen[cat] += 1
    box = None
    for v in item.each_value():
        for getter in ("box", "polygon", "edge_pair", "edge", "path"):
            try:
                g = getattr(v, getter)()
                if g is not None:
                    b = g if isinstance(g, pya.DBox) else g.bbox()
                    box = b if box is None else box + b
                    break
            except Exception:
                continue
    if box is None:
        per_cat[cat]["<no geometry>"] += 1
        continue
    ibox = box.to_itype(ly.dbu).enlarged(1, 1)
    leaf = {}
    it = top.begin_instances_rec_overlapping(ibox)
    while not it.at_end():
        path = [ly.cell(e.cell_inst().cell_index).name for e in it.path()] + [it.inst_cell().name]
        key = path[0]
        if len(path) > len(leaf.get(key, [])):
            leaf[key] = path
        it.next()
    if not leaf:
        # name the top-level shapes under the marker: layer/datatype and size
        hits = []
        for li in ly.layer_indexes():
            info = ly.get_info(li)
            for sh in top.shapes(li).each_overlapping(ibox):
                b = sh.bbox()
                hits.append(f"{info.layer}/{info.datatype} {b.width() * ly.dbu:.2f}x{b.height() * ly.dbu:.2f}")
        per_cat[cat]["<top> " + (", ".join(sorted(set(hits))[:4]) or "nothing")] += 1
    else:
        # deepest description of each top-level instance hit
        for path in leaf.values():
            # master of the hit: a std cell at depth 1, or "macro > subcell"
            per_cat[cat][" > ".join(path[:2])] += 1

for cat, cnt in per_cat.items():
    print(f"== {cat}  (sampled {seen[cat]})")
    for name, k in cnt.most_common(8):
        print(f"   {k:5d}  {name}")
