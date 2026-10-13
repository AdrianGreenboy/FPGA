"""strap_pin_clash.py : do the Metal2 density straps collide with tile IO pins?

    ODB=<tile.odb> openroad -python -exit scripts/strap_pin_clash.py
    (several databases: ODB="a.odb b.odb")

Background: fabric/Tile/include/pdn_m2_density.tcl adds vertical Metal2
VDD/VSS straps (1.2 um, pitch 50 um) to the big tiles. FABulous places the tile
IO pins itself and their x positions move with the die width the NLP picks, so
a strap can land on (or within min. spacing of) a Metal2 pin at a die size that
was never tried in the exploration step. The router cannot repair that - it
shows up as a fixed number of Metal2 shorts that never go away (DSP, step 3,
"14 violations" in every iteration until the 900 s DRT timeout).

Prints die size, the strap x ranges, Metal2 pins per edge, and every pin whose
box overlaps or comes closer than M2 min. spacing (0.21 um) to a strap.
"""
import os
import sys

import odb

M2_SPACING = 0.21

paths = (os.environ.get("ODB") or " ".join(sys.argv[1:])).split()
if not paths:
    sys.exit(__doc__)

dbs = []  # keep every database alive: dropping one can segfault later odb calls
for path in paths:
    db = odb.dbDatabase.create()  # one db per file (Design.readDb refuses a 2nd: ORD-0047)
    odb.read_db(db, path)
    dbs.append(db)
    block = db.getChip().getBlock()
    dbu = block.getDbUnitsPerMicron()
    die = block.getDieArea()
    W, H = die.xMax() / dbu, die.yMax() / dbu
    print(f"\n=== {path}\n  die {W:.2f} x {H:.2f} um")

    straps = []  # (net, x0, y0, x1, y1) in um, Metal2 special wires
    for net in block.getNets():
        if not net.isSpecial():
            continue
        for sw in net.getSWires():
            for b in sw.getWires():
                if b.isVia():
                    continue
                lay = b.getTechLayer()
                if lay is None or lay.getName() != "Metal2":
                    continue
                # straps are vertical and long; skip short M2 bits (via pads)
                if (b.yMax() - b.yMin()) < 10 * dbu:
                    continue
                straps.append((net.getName(), b.xMin() / dbu, b.yMin() / dbu,
                               b.xMax() / dbu, b.yMax() / dbu))
    xs = sorted({(round(s[1], 3), round(s[3], 3)) for s in straps})
    print(f"  Metal2 straps: {len(straps)} wires, x ranges: "
          + ", ".join(f"{a:.2f}-{b:.2f}" for a, b in xs[:12]) + (" ..." if len(xs) > 12 else ""))
    if straps:
        print(f"  strap y span: {min(s[2] for s in straps):.2f} .. {max(s[4] for s in straps):.2f}")

    pins = []  # (name, edge, x0, y0, x1, y1)
    per_edge = {"N": 0, "S": 0, "E": 0, "W": 0, "inside": 0}
    for bt in block.getBTerms():
        for bp in bt.getBPins():
            for b in bp.getBoxes():
                lay = b.getTechLayer()
                if lay is None or lay.getName() != "Metal2":
                    continue
                x0, y0, x1, y1 = (b.xMin() / dbu, b.yMin() / dbu, b.xMax() / dbu, b.yMax() / dbu)
                edge = ("S" if y0 <= 0.01 else "N" if y1 >= H - 0.01 else
                        "W" if x0 <= 0.01 else "E" if x1 >= W - 0.01 else "inside")
                per_edge[edge] += 1
                pins.append((bt.getName(), edge, x0, y0, x1, y1))
    print(f"  Metal2 pins per edge: {per_edge}")

    clashes = []
    for name, edge, px0, py0, px1, py1 in pins:
        for net, sx0, sy0, sx1, sy1 in straps:
            dx = max(sx0 - px1, px0 - sx1, 0.0)
            dy = max(sy0 - py1, py0 - sy1, 0.0)
            d = (dx * dx + dy * dy) ** 0.5
            if d < M2_SPACING:
                clashes.append((d, name, edge, px0, py0, px1, py1, net))
    if not clashes:
        print("  no Metal2 pin within min. spacing of a strap")
    else:
        print(f"  {len(clashes)} pin/strap pairs closer than {M2_SPACING} um "
              f"(0.00 = overlap):")
        for d, name, edge, px0, py0, px1, py1, net in sorted(clashes)[:30]:
            print(f"    {d:5.2f}  {name:28s} edge {edge}  pin x {px0:.2f}-{px1:.2f} "
                  f"y {py0:.2f}-{py1:.2f}  vs {net}")
