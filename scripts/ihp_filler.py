"""ihp_filler.py : IHP SG13G2 fill with a tighter metal filler pitch.

Drop-in replacement for the PDK's libs.tech/klayout/tech/scripts/filler.py
(same command line, so LibreLane can use it as KLAYOUT_FILLER_SCRIPT):

    klayout -b -zz -r scripts/ihp_filler.py -rd output_file=out.gds in.gds \
            [-rd metal_distance=0.42] [-rd m1_distance=1.5] [-rd no_auto_origin]

Why: in batch mode the PDK's sg13g2_filler_Metal.lym uses fixed filler-to-
filler distances of 1.5 um (Metal1/2) and 2.0 um (Metal3-5). Inside the
FABulous fabric the routing leaves only narrow gaps, so with that coarse
fixed-origin grid almost nothing fits: an 800 um window inside the eFPGA
ended at Metal2 19.7 %, Metal3 23.4 %, Metal4 17.5 %, Metal5 16.7 % (metal +
filler) against the 25 % minimum of MxFil.h (IHP precheck). The rules allow
0.42 um filler-to-filler (MxFil.b) and filler-to-metal (MxFil.c), so this
wrapper rewrites the distances (Metal2-5 by default) and lets every fill pass
pick its own origin per polygon (auto_origin), then runs the PDK macro
unchanged otherwise. Activ/GatPoly and TopMetal fill use the PDK macros as is.
"""
# pylint: disable=import-error,undefined-variable
import os
import pathlib
import re
import sys
import tempfile

import pya

try:
    output_file
except NameError:
    print("Missing output_file argument. Please define '-rd output_file=<path-to-output-file>'")
    sys.exit(1)

g = globals()
MD = float(g.get("metal_distance", 0.42))
M1D = float(g.get("m1_distance", 1.5))
# Metal5 at 0.42 everywhere overshoots M5.k (max. GLOBAL Metal5 density 60 %)
# because the large empty chip areas fill to ~50 % on top of the routing;
# 1.0 um is the compromise to verify: eFPGA windows need >= 25 % (PDK's 2.0 um
# gave 16.7 %, 0.42 um gave 37.8 %).
M5D = float(g.get("m5_distance", 1.0))
AUTO = "no_auto_origin" not in g
if min(MD, M1D, M5D) < 0.42:
    sys.exit("filler distances below 0.42 um violate MxFil.b")

macros = pathlib.Path(os.environ["PDK_ROOT"]) / os.environ["PDK"] / "libs.tech/klayout/tech/macros"


def run(path):
    pya.Macro(str(path)).run()


def patched_metal():
    src = (macros / "sg13g2_filler_Metal.lym").read_text()
    dist = {"distance_m1": M1D, "distance_m2": MD, "distance_m3": MD, "distance_m4": MD, "distance_m5": M5D}
    n = 0
    for k, v in dist.items():
        src, c = re.subn(r"('%s'\s*=>\s*)[\d.]+" % k, r"\g<1>%s" % v, src)
        n += c
    if n != 5:
        sys.exit("sg13g2_filler_Metal.lym changed upstream (distances block) - update ihp_filler.py")
    if AUTO:
        src, c = re.subn(r"(\.fill(?:_with_left)?\([^\n]*vstep\([^)]*\))\)", r"\1, auto_origin)", src)
        if c != 10:
            sys.exit(f"sg13g2_filler_Metal.lym changed upstream (fill calls: {c}) - update ihp_filler.py")
    # Metal2-5: after the small-square pass, three more passes on what is left
    # with the grid shifted by half a pitch in x, y and both. Each pass works on
    # the previous pass' leftover region, so filler-filler spacing stays >= the
    # pitch gap (checked: 0 MxFil.b / .c / .a1 violations on a random layout).
    def multipass(m):
        n = m.group(1)
        st = f"(width_m{n}_s + distance_m{n}_s)"
        sh = f"(width_m{n}_s + distance_m{n}_s) / 2.0"
        pat = f"pattern_m{n}_s, hstep{st[0:0]}({st}), vstep({st})"
        return (f"M{n}Fil_p1 = M{n}Fil_left.fill_with_left({pat}{', auto_origin' if AUTO else ''})\n"
                f"\tM{n}Fil_p2 = M{n}Fil_p1.fill_with_left({pat}, origin({sh}, 0.0))\n"
                f"\tM{n}Fil_p3 = M{n}Fil_p2.fill_with_left({pat}, origin(0.0, {sh}))\n"
                f"\tM{n}Fil_p3.fill({pat}, origin({sh}, {sh}))")
    src, c = re.subn(r"M([2-5])Fil_left\.fill\(pattern_m\1_s,[^\n]*\)", multipass, src)
    if c != 4:
        sys.exit(f"sg13g2_filler_Metal.lym changed upstream (small fill lines: {c}) - update ihp_filler.py")
    tmp = pathlib.Path(tempfile.mkdtemp()) / "sg13g2_filler_Metal_tight.lym"
    tmp.write_text(src)
    return tmp


if "no_activ" not in g:
    print("Start filling ActGatP (PDK macro)")
    run(macros / "sg13g2_filler_ActGatP.lym")
if "no_metal" not in g:
    print(f"Start filling Metal (filler distance M1 {M1D}, M2-M4 {MD}, M5 {M5D} um, auto_origin={AUTO})")
    run(patched_metal())
if "no_topmetal" not in g:
    print("Start filling TopMetal (PDK macro)")
    run(macros / "sg13g2_filler_TopMetal.lym")

pya.CellView.active().layout().write(output_file)
