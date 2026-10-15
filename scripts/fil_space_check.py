# fil_space_check.py : verify metal-filler spacing rules the open deck skips.
#
#   klayout -b -zz -r scripts/fil_space_check.py -rd gds=<filled.gds>
#
# The open PDK deck only implements MFil.c (filler to drawing metal, 0.42,
# precheck) and MFil.a2 (max width 5.0). The DRM (SG13G2_os_layout_rules 5.18)
# also requires MFil.b (filler to filler >= 0.42) and MFil.a1 (min filler
# width 1.0) - IHP's internal sign-off can check them even though the open
# deck never does. scripts/ihp_filler.py places fill on mixed lattices
# (strips at 5.42 pitch, squares at 1.42), so b must be verified, not assumed.
import pya

gds = globals().get("gds")
if not gds:
    raise SystemExit("usage: klayout -b -zz -r fil_space_check.py -rd gds=...")
ly = pya.Layout()
ly.read(gds)
top = ly.top_cell()
FILLER = {"Metal1": (8, 22), "Metal2": (10, 22), "Metal3": (30, 22),
          "Metal4": (50, 22), "Metal5": (67, 22)}
bad = 0
for name, (la, dt) in FILLER.items():
    li = ly.find_layer(la, dt)
    if li is None:
        print(f"{name:7s} no filler layer")
        continue
    r = pya.Region(top.begin_shapes_rec(li))
    r.merge()
    n = r.count()
    sp = r.space_check(420)                      # MFil.b 0.42 um in dbu
    nar = r.width_check(999)                     # MFil.a1 1.0 um (999 dbu: < 1.0)
    wide = sum(1 for p in r.each() if min(p.bbox().width(), p.bbox().height()) > 5001)
    print(f"{name:7s} {n:8d} fillers | b space<0.42: {sp.count():6d} | "
          f"a1 width<1.0: {nar.count():6d} | a2 side>5.0: {wide:6d}")
    bad += sp.count() + nar.count() + wide
print(f"TOTAL violations: {bad}")
