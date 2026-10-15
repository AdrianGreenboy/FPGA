# offgrid_check.py : count polygon vertices off the 5 nm manufacturing grid.
#
#   klayout -b -zz -r scripts/offgrid_check.py -rd gds=<file.gds> [-rd grid=0.005]
#
# Fast stand-in for the OffGrid.* rules of the IHP deck: reports, per layer,
# how many shapes have at least one vertex that is not a multiple of the grid
# (flat view, so instance origins count too - exactly what the deck checks).
# Used to verify a refill in seconds instead of re-running the 36 min
# sg13g2_maximal runset: the first chip GDS had 4.7 M off-grid filler vertices
# from auto_origin fill arrays (see scripts/ihp_filler.py).
import pya

gds = globals().get("gds")
grid = float(globals().get("grid", 0.005))
if not gds:
    raise SystemExit("usage: klayout -b -zz -r offgrid_check.py -rd gds=...")

ly = pya.Layout()
ly.read(gds)
top = ly.top_cell()
g = int(round(grid / ly.dbu))
total = 0
print(f"grid {grid} um = {g} dbu, top {top.name}")
for li in ly.layer_indexes():
    info = ly.get_info(li)
    bad = 0
    n = 0
    for sh in top.begin_shapes_rec(li):  # flat: transformed to top
        n += 1
        poly = sh.shape().polygon
        if poly is None:
            continue
        poly = poly.transformed(sh.trans())
        off = False
        for pt in poly.each_point_hull():
            if pt.x % g or pt.y % g:
                off = True
                break
        if off:
            bad += 1
    if n:
        flag = "  <-- OFF GRID" if bad else ""
        print(f"  {info.layer:3d}/{info.datatype:<3d} {n:9d} shapes, {bad:9d} off-grid{flag}")
    total += bad
print(f"TOTAL off-grid shapes: {total}")
