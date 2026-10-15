# nwd_patch.py : close the 4 NW.d markers at the SRAM-halo ragged row ends.
#
#   klayout -b -zz -r scripts/nwd_patch.py -rd gds=<final.gds> -rd out=<tapeout.gds>
#
# At four spots (two per SRAM macro) a cell row ends 0.24 um short of its
# neighbour, and the n-well tie strip of the longer row keeps only its own
# 0.24 um NWell enclosure (= the PDK's NW.e minimum) instead of the extra
# overlap the neighbouring row's NWell normally adds. The maximal runset's
# NW.d (NWell space to external N+Activ >= 0.31, deck line 2038) flags the
# merged-well notch corner against that tie strip.
#
# Fix: four NWell rectangles that fill the notch, raising the tie enclosure
# to >= 0.55 um. Each rectangle overlaps the existing (VDD-tied) wells, so
# it merges with them - no new floating well, no device change, LVS
# connectivity unchanged. Coordinates are from the final GDS of
# RUN_2026-10-14_22-32-03 and are 5 nm grid aligned; re-derive them (see
# README) if the placement ever changes.
# pylint: disable=import-error,undefined-variable
import pya

g = globals()
gds, out = g.get("gds"), g.get("out")
if not gds or not out:
    raise SystemExit("usage: klayout -b -zz -r nwd_patch.py -rd gds=in.gds -rd out=out.gds")

RECTS = [  # um, (x1, y1, x2, y2) on NWell 31/0, chip_top top level
    (2790.90, 1326.93, 3511.92, 1327.48),
    (2790.90, 1484.84, 3511.92, 1485.39),
    (2790.90, 2302.17, 3511.92, 2302.72),
    (2790.90, 2460.08, 3511.92, 2460.63),
]

ly = pya.Layout()
ly.read(gds)
top = ly.top_cell()
li = ly.layer(31, 0)
dbu = ly.dbu
for x1, y1, x2, y2 in RECTS:
    top.shapes(li).insert(pya.Box(int(round(x1 / dbu)), int(round(y1 / dbu)),
                                  int(round(x2 / dbu)), int(round(y2 / dbu))))
    print(f"NWell patch ({x1},{y1} ; {x2},{y2})")
ly.write(out)
print(f"wrote {out}")
