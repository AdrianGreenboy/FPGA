"""net_report.py : driver, sinks, HPWL and routed length of the nets on given pins.

    ODB=<final.odb> PINS="_4256_/Y fanout139/A ..." openroad -python -exit scripts/net_report.py

For each pin (inst/mterm) prints the instance master and location, its net,
the driver (master, position), the number of sinks, the half-perimeter of all
pins and the routed length from the odb wire (when the db is routed). Used to
tell a weak driver on a long net (-> buffer/upsize) from a short net whose
slew is inherited from its input (-> fix upstream).
"""
import os
import sys

import odb

path = os.environ.get("ODB")
pins = os.environ.get("PINS", " ".join(sys.argv[1:])).split()
if not path or not pins:
    sys.exit(__doc__)
db = odb.dbDatabase.create()
odb.read_db(db, path)
block = db.getChip().getBlock()
dbu = block.getDbUnitsPerMicron()


def um(v):
    return v / dbu


def center(it):
    try:  # pin shape (matters for macros: eFPGA / SRAM pins are far from the centre)
        b = it.getBBox()
    except Exception:
        b = it.getInst().getBBox()
    return (b.xMin() + b.xMax()) / 2, (b.yMin() + b.yMax()) / 2


for p in pins:
    iname, _, mterm = p.rpartition("/")
    inst = block.findInst(iname)
    if inst is None:
        print(f"{p}: instance not found")
        continue
    it = inst.findITerm(mterm)
    net = it.getNet() if it else None
    x, y = center(it)
    print(f"\n{p}: {inst.getMaster().getName()} at ({um(x):.1f}, {um(y):.1f})")
    if net is None:
        print("  no net")
        continue
    drv, sinks, pts = None, [], []
    for t in net.getITerms():
        pts.append(center(t))
        if t.isOutputSignal():
            drv = t
        else:
            sinks.append(t)
    for bt in net.getBTerms():
        for bp in bt.getBPins():
            for b in bp.getBoxes():
                pts.append(((b.xMin() + b.xMax()) / 2, (b.yMin() + b.yMax()) / 2))
    hp = um(max(q[0] for q in pts) - min(q[0] for q in pts) + max(q[1] for q in pts) - min(q[1] for q in pts))
    routed = None
    w = net.getWire()
    if w is not None:
        try:
            routed = um(w.getLength())
        except Exception:
            routed = None
    d = "?"
    if drv is not None:
        dx, dy = center(drv)
        d = f"{drv.getInst().getName()}/{drv.getMTerm().getName()} ({drv.getInst().getMaster().getName()}) at ({um(dx):.1f}, {um(dy):.1f})"
        # what drives the driver's inputs (inherited slew?)
        for t in drv.getInst().getITerms():
            if t.isInputSignal() and t.getNet() is not None:
                src = [s for s in t.getNet().getITerms() if s.isOutputSignal()]
                s = src[0] if src else None
                sd = f"{s.getInst().getName()} ({s.getInst().getMaster().getName()})" if s else "top/macro pin"
                d += f"\n    input {t.getMTerm().getName()} <- {sd}"
    print(f"  net {net.getName()}: {len(sinks)} sinks, HPWL {hp:.0f} um, routed {routed if routed is None else f'{routed:.0f} um'}")
    print(f"  driver {d}")
    for t in sinks[:6]:
        sx, sy = center(t)
        print(f"    sink {t.getInst().getName()}/{t.getMTerm().getName()} ({t.getInst().getMaster().getName()}) at ({um(sx):.1f}, {um(sy):.1f})")
