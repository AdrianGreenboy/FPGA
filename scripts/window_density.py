# window_density.py : metal and metal-filler coverage of one window of a GDS
#
#   klayout -b -r scripts/window_density.py -rd gds=<file.gds> [-rd box=x1,y1,x2,y2]
#
# Prints, per Metal1..Metal5 / TopMetal1..2: drawing (n/0) and filler (n/22)
# coverage in the window (default: 800,800,1600,1600 um), merged over the
# whole hierarchy. Tells whether a density failure is "no fill got in" or
# "fill got in but the window is still too sparse".
import pya

gds = globals().get("gds")
box = [float(v) for v in globals().get("box", "800,800,1600,1600").split(",")]
ly = pya.Layout()
ly.read(gds)
top = ly.top_cell()
win = pya.Region(pya.Box(*(round(v / ly.dbu) for v in box)))
area = win.area()
for name, n in (("Metal1", 8), ("Metal2", 10), ("Metal3", 30), ("Metal4", 50), ("Metal5", 67),
                ("TopMetal1", 126), ("TopMetal2", 134)):
    out = []
    for dt in (0, 22):
        li = ly.find_layer(n, dt)
        if li is None:
            out.append("   -  ")
            continue
        r = pya.Region(top.begin_shapes_rec_touching(li, win.bbox())) & win
        out.append(f"{100.0 * r.merged().area() / area:5.1f}%")
    print(f"{name:10s} drawing {out[0]}  filler {out[1]}")
