#!/usr/bin/env python3
"""lef_report.py : summarise a macro LEF for top-level integration planning.

    scripts/lef_report.py <macro.lef> [more.lef ...]

Prints per macro: size, power/ground pins (layers, stripe direction, extent -
do the stripes span the whole macro?), signal pins grouped by edge, layer and
name prefix (Tile_XnYm for FABulous fabrics), and the OBS layers. This is what
decides the eFPGA_top floorplan (which edge the RAM ports leave from) and the
PDN strategy (which layers the top-level grid may use over each macro).
"""
import collections
import re
import sys


def sides(x1, y1, x2, y2, w, h, tol):
    s = []
    if y1 <= tol:
        s.append("S")
    if y2 >= h - tol:
        s.append("N")
    if x1 <= tol:
        s.append("W")
    if x2 >= w - tol:
        s.append("E")
    return s or ["inside"]


def report(path):
    txt = open(path).read()
    for mm in re.finditer(r"^MACRO\s+(\S+)(.*?)^END\s+\1", txt, re.S | re.M):
        name, body = mm.groups()
        w, h = map(float, re.search(r"SIZE\s+([\d.]+)\s+BY\s+([\d.]+)", body).groups())
        tol = 2.0
        print(f"== {name}: {w} x {h} um ({w * h / 1e6:.3f} mm2)  [{path}]")
        sig = collections.Counter()
        for pm in re.finditer(r"^\s*PIN\s+(\S+)(.*?)^\s*END\s+\1\s*$", body, re.S | re.M):
            pin, pb = pm.groups()
            use = re.search(r"USE\s+(\w+)", pb)
            use = use.group(1).upper() if use else "SIGNAL"
            rects = []
            for lay, rs in re.findall(r"LAYER\s+(\S+)\s*;((?:\s*RECT[^;]*;)+)", pb):
                for r in re.findall(r"RECT\s+([\d.\-]+)\s+([\d.\-]+)\s+([\d.\-]+)\s+([\d.\-]+)", rs):
                    rects.append((lay, *map(float, r)))
            if use in ("POWER", "GROUND"):
                print(f"  {use:6s} {pin}")
                by = collections.defaultdict(list)
                for lay, x1, y1, x2, y2 in rects:
                    by[lay].append((x1, y1, x2, y2))
                for lay, rr in sorted(by.items()):
                    vert = sum(1 for x1, y1, x2, y2 in rr if (y2 - y1) > (x2 - x1))
                    hor = len(rr) - vert
                    full_v = sum(1 for x1, y1, x2, y2 in rr if (y2 - y1) > (x2 - x1) and y2 - y1 >= 0.9 * h)
                    full_h = sum(1 for x1, y1, x2, y2 in rr if (x2 - x1) >= (y2 - y1) and x2 - x1 >= 0.9 * w)
                    widths = sorted({round(min(x2 - x1, y2 - y1), 2) for x1, y1, x2, y2 in rr})
                    xs = sorted(round((x1 + x2) / 2, 2) for x1, y1, x2, y2 in rr if (y2 - y1) > (x2 - x1))
                    ys = sorted(round((y1 + y2) / 2, 2) for x1, y1, x2, y2 in rr if (x2 - x1) >= (y2 - y1))
                    print(f"         {lay:10s} {len(rr):4d} rects: {vert} vertical ({full_v} full-height), "
                          f"{hor} horizontal ({full_h} full-width), widths {widths[:4]}")
                    if xs:
                        print(f"           vertical x: {xs[:4]}{' ...' if len(xs) > 4 else ''}"
                              f"{' pitch %.2f' % (xs[1] - xs[0]) if len(xs) > 1 else ''}")
                    if ys:
                        print(f"           horizontal y: {ys[:4]}{' ...' if len(ys) > 4 else ''}"
                              f"{' pitch %.2f' % (ys[1] - ys[0]) if len(ys) > 1 else ''}")
            else:
                base = re.sub(r"\[\d+\]$", "", pin)
                m = re.match(r"(Tile_X\d+Y\d+)_(.*)", base)
                group = m.group(1) + "_" + re.sub(r"\d+$", "*", m.group(2)) if m else re.sub(r"\d+$", "*", base)
                for lay, x1, y1, x2, y2 in rects[:1]:
                    for s in sides(x1, y1, x2, y2, w, h, tol):
                        sig[(s, lay, group)] += 1
        per_side = collections.Counter()
        for (s, lay, g), n in sig.items():
            per_side[(s, lay)] += n
        print("  signal pins per edge/layer:", dict(sorted(per_side.items())))
        interesting = [k for k in sig if re.search(r"RAM|BRAM|DATA|ADDR|DIN|DOUT|CLK|Frame|config|_O_|_I_", k[2], re.I)]
        shown = sorted(interesting or sig, key=lambda k: (k[0], k[2]))
        print(f"  signal groups (edge layer group count){' - RAM/clock/config related' if interesting else ''}:")
        for k in shown[:60]:
            print(f"    {k[0]:6s} {k[1]:8s} {k[2]:40s} {sig[k]}")
        if len(shown) > 60:
            print(f"    ... {len(shown) - 60} more groups")
        obs = re.search(r"^\s*OBS(.*?)^\s*END\s*$", body, re.S | re.M)
        print("  OBS layers:", sorted(set(re.findall(r"LAYER\s+(\S+)", obs.group(1)))) if obs else "  OBS: none")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    for p in sys.argv[1:]:
        report(p)
