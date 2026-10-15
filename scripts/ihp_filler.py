"""ihp_filler.py : IHP SG13G2 fill with a tighter metal filler pitch.

Drop-in replacement for the PDK's libs.tech/klayout/tech/scripts/filler.py
(same command line, so LibreLane can use it as KLAYOUT_FILLER_SCRIPT):

    klayout -b -zz -r scripts/ihp_filler.py -rd output_file=out.gds in.gds \
            [-rd metal_distance=0.42] [-rd m1_distance=1.5] [-rd no_snap]

Why: in batch mode the PDK's sg13g2_filler_Metal.lym uses fixed filler-to-
filler distances of 1.5 um (Metal1/2) and 2.0 um (Metal3-5) and a fixed fill
origin. Inside the FABulous fabric the routing leaves only narrow gaps, so
almost nothing fits and MFil.h (>= 25 % metal+filler per 800x800 um window)
fails on Metal2/3. Two changes, PDK macros otherwise unchanged:

1. distances: 0.42 um (MFil.b per the DRM) for Metal2-4, 1.0 for Metal5
   (0.42 overshoots the global Metal5 cap: ~50 % over the empty chip areas),
   m1_distance for Metal1 - and every fill pass runs with auto_origin.
   auto_origin anchors per leftover island and KEEPS RE-ANCHORING on the
   remains until nothing fits, which is what the fabric needs: every on-grid
   scheme tried (fixed origins + half-pitch passes; per-island corner-snapped
   lattices, plain and phase-bucketed) placed ~40 % fewer 2.42 um medium
   squares in the fabric windows and left 17-18 M2Fil.h/M3Fil.h windows
   below 25 %, while auto_origin passes the official density check.
2. auto_origin anchors at raw island corners, and regions with off-5nm-grid
   vertices (sized 45-degree seal-ring edges) put entire fill arrays off the
   manufacturing grid - 4.7 M OffGrid.MetalX_filler violations in the first
   precheck. So after filling, every *FILL_CELL* instance origin is snapped
   to the 5 nm grid (<= 2.5 nm move). Cells of one array share the phase and
   move rigidly, so the exact 0.42 um in-array gaps survive; the margin to
   drawn metal is pre-widened from 0.42 to 0.43 um in the region derivation
   so the snap can never push a filler under MFil.c's 0.42. 0.43, not 0.425:
   against a 45-degree edge (pad-ring corner chamfers) the snap subtracts up
   to sqrt(2)*2.5 = 3.5 nm of EUCLIDEAN distance, and the sized region's
   chamfered corners leave slightly less than the nominal margin - with
   0.425 one corner structure landed at 0.4207 pre-snap and 0.4172 after
   (412 M*Fil.c markers). Verify with scripts/offgrid_check.py,
   scripts/fil_space_check.py, the main deck ihp-sg13g2.drc and the PDK's
   run_drc.py --density_only.
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
M5D = float(g.get("m5_distance", 1.0))
SNAP = "no_snap" not in g
if min(MD, M1D, M5D) < 0.42:
    sys.exit("filler distances below 0.42 um violate MFil.b")

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
    # every fill pass per-island and iterative (see docstring, change 1)
    src, c = re.subn(r"(\.fill(?:_with_left)?\([^\n]*vstep\([^)]*\))\)", r"\1, auto_origin)", src)
    if c != 10:
        sys.exit(f"sg13g2_filler_Metal.lym changed upstream (fill calls: {c}) - update ihp_filler.py")
    if SNAP:
        # widen the filler-to-metal margin 0.42 -> 0.43 so the <= 2.5 nm
        # instance snap below cannot shave MFil.c under 0.42
        src, c = re.subn(r"\.size\(0\.42, 0\.42, \"square_limit\"\)",
                         '.size(0.43, 0.43, "square_limit")', src)
        if c != 10:
            sys.exit(f"sg13g2_filler_Metal.lym changed upstream (0.42 sizings: {c}) - update ihp_filler.py")
    tmp = pathlib.Path(tempfile.mkdtemp()) / "sg13g2_filler_Metal_tight.lym"
    tmp.write_text(src)
    return tmp


def snap_fill_instances(path):
    """Snap every *FILL_CELL* instance origin to the 5 nm grid (change 2).

    Works on a standalone re-loaded layout: the batch CellView layout is not
    editable ("Function permitted on editable layouts only"), and LibreLane
    calls this script with fixed klayout arguments, so -e is not an option.
    """
    ly = pya.Layout()
    ly.read(path)
    top = ly.top_cell()
    grid = int(round(0.005 / ly.dbu))
    moved = total = 0
    for inst in top.each_inst():
        if "FILL_CELL" not in inst.cell.name:
            continue
        total += 1
        t = inst.cplx_trans
        x, y = t.disp.x, t.disp.y
        sx = int(round(x / grid)) * grid
        sy = int(round(y / grid)) * grid
        if sx != x or sy != y:
            t.disp = pya.Vector(sx, sy)
            inst.cplx_trans = t
            moved += 1
    print(f"snap_fill_instances: {moved} of {total} fill instances snapped to the 5 nm grid")
    ly.write(path)


if "no_activ" not in g:
    print("Start filling ActGatP (PDK macro)")
    run(macros / "sg13g2_filler_ActGatP.lym")
if "no_metal" not in g:
    print(f"Start filling Metal (filler distance M1 {M1D}, M2-M4 {MD}, M5 {M5D} um, "
          f"auto_origin + instance snap={SNAP})")
    run(patched_metal())
if "no_topmetal" not in g:
    print("Start filling TopMetal (PDK macro)")
    run(macros / "sg13g2_filler_TopMetal.lym")
pya.CellView.active().layout().write(output_file)
if SNAP:
    snap_fill_instances(output_file)
