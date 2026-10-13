#!/usr/bin/env python3
"""gen_top_config.py : LibreLane config for hardening eFPGA_top on IHP SG13G2.

    scripts/gen_top_config.py [--out build/top] [--clock-period 20]

eFPGA_top = config logic (eFPGA_Config, Frame_Data_Reg x8, Frame_Select x10)
          + the hardened eFPGA macro (Fabric/macro/final_views)
          + 4x BlockRAM_1KB, each wrapping one IHP RM_IHPSG13_2P_256x32_c2_bm_bist
            through rtl/asic/ihp/sram_1rw1r_32_256_8_sky130.v.

Everything physical is derived from the LEFs, not hard-coded:
  * eFPGA size and the y-span of each RAM_IO tile's pins on its east edge
    (BlockRAM k <-> tiles X9Y(8-2k)/X9Y(7-2k), from eFPGA_top.v)
  * SRAM size; its 372 signal pins are all on the south edge (Metal2)

Floorplan ("east", default): eFPGA at the lower left, a column of 4 SRAMs (N
orientation) to its east, each top-aligned with its RAM_IO tile pair, so the
pins face down into a ~300 um channel at the height of the RAM_IO ports -
short, straight routes. The SRAM column is 703 um wide for 137 um tall macros,
so this is not area-optimal; it is the low-risk first closure.

Power: top-level grid TopMetal1 (vertical) + TopMetal2 (horizontal), Metal1
rails for the config logic.
  * eFPGA: VPWR/VGND pins are TopMetal1 stripes and its OBS stops at TopMetal1
    -> TopMetal2 straps cross it; LibreLane's default macro grid (TM1-TM2
    connect) makes the vias.
  * SRAM: VDD!/VDDARRAY!/VSS! are Metal4 stripes, OBS up to Metal4 -> a
    second macro grid (pdn_top.tcl, by master cell) connects TopMetal2 down
    to Metal4. VDDARRAY! goes to VPWR (single 1.2 V supply).
Signal routing stops at Metal5 (free over the SRAMs, TopMetal1/2 are PDN).

Synthesis sees both macros as blackboxes generated from their LEFs. The eFPGA
has no liberty: STA does not time paths into/out of the fabric at this level.
"""
import argparse
import collections
import os
import re
import sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRAM = "RM_IHPSG13_2P_256x32_c2_bm_bist"
# sg13g2 core site 0.48 x 3.78 um: snap macro origins to it
SITE_X, SITE_Y = 0.48, 3.78


def snap(v, g):
    return round(round(v / g) * g, 3)


def parse_lef(path, macro):
    txt = open(path).read()
    m = re.search(r"^MACRO\s+%s\b(.*?)^END\s+%s" % (re.escape(macro), re.escape(macro)), txt, re.S | re.M)
    if not m:
        sys.exit(f"{path}: MACRO {macro} not found")
    body = m.group(1)
    w, h = map(float, re.search(r"SIZE\s+([\d.]+)\s+BY\s+([\d.]+)", body).groups())
    pins = {}
    for pm in re.finditer(r"^\s*PIN\s+(\S+)(.*?)^\s*END\s+\1\s*$", body, re.S | re.M):
        name, pb = pm.groups()
        d = re.search(r"DIRECTION\s+(\w+)", pb)
        u = re.search(r"USE\s+(\w+)", pb)
        rects = [tuple(map(float, r)) for r in
                 re.findall(r"RECT\s+([\d.\-]+)\s+([\d.\-]+)\s+([\d.\-]+)\s+([\d.\-]+)", pb)]
        pins[name] = dict(dir=(d.group(1) if d else "INPUT").upper(),
                          use=(u.group(1) if u else "SIGNAL").upper(), rects=rects)
    return w, h, pins


# SRAM pin -> per-pin buffer group of rtl/asic/ihp/sram_1rw1r_32_256_8_sky130.v
SRAM_PIN_BUFS = {"A_DIN": "u_pb_din", "A_BM": "u_pb_bm", "A_ADDR": "u_pb_addr0",
                 "B_ADDR": "u_pb_addr1", "A_MEN": "u_pb_amen", "A_WEN": "u_pb_awen",
                 "B_MEN": "u_pb_bmen", "B_REN": "u_pb_bren", "B_DOUT": "u_pb_dout1"}
SRAM_BUF_GAP = 16.0  # um below the SRAM edge: past the 10 um row-cut halo


def sram_buffer_placements(srams, spins, cell_tmpl, q):
    """MANUAL_GLOBAL_PLACEMENTS for the kept per-pin SRAM buffers.

    Global placement treats a buffer between an SRAM pin and the fabric as free
    to sit anywhere on that line (same HPWL), so some ended hundreds of um from
    the SRAM: chip run 2026-10-13 had 12 B_DOUT pins driving 0.066-0.091 pF
    (liberty max 0.064 pF, a macro output cannot be upsized or repaired). The
    whole point of the buffers is to sit AT the pin, so put each one right
    below its pin (all SRAM signal pins are on the south edge, checked in
    main()); Odb.ManualGlobalPlacement runs after global placement and
    detailed placement legalises them. Long wires on the far side are left to
    the resizer (DESIGN_REPAIR_MAX_WIRE_LENGTH).
    """
    lines = []
    for s in srams:
        cell = cell_tmpl.format(k=s["k"])
        for pin, p in spins.items():
            m = re.match(r"([A-Z_]+?)(?:\[(\d+)\])?$", pin)
            if not m or m.group(1) not in SRAM_PIN_BUFS or not p["rects"]:
                continue
            bit = int(m.group(2) or 0)
            r = p["rects"][0]
            x = round(s["x"] + (r[0] + r[2]) / 2 - 1.0, 3)
            y = round(s["y"] - SRAM_BUF_GAP, 3)
            inst = f"{cell}.{SRAM_PIN_BUFS[m.group(1)]}.g[{bit}].u_buf"
            lines.append(f"  {q(inst)}:\n    location: [{x}, {y}]\n    orientation: N")
    if not lines:
        sys.exit("no SRAM pins matched the per-pin buffer map - SRAM LEF pin names changed?")
    return ("\n# per-pin SRAM buffers right below their pins (see sram_buffer_placements)\n"
            "MANUAL_GLOBAL_PLACEMENTS:\n" + "\n".join(lines) + "\n")


def blackbox(module, pins):
    """Verilog blackbox from LEF pins (buses rebuilt from name[i])."""
    buses = collections.OrderedDict()
    for name, p in pins.items():
        if p["use"] in ("POWER", "GROUND"):
            continue
        m = re.match(r"(.+)\[(\d+)\]$", name)
        base, idx = (m.group(1), int(m.group(2))) if m else (name, None)
        b = buses.setdefault(base, dict(dir=p["dir"], idx=[]))
        if idx is not None:
            b["idx"].append(idx)
    kw = {"INPUT": "input", "OUTPUT": "output", "INOUT": "inout"}
    ports = []
    for base, b in buses.items():
        rng = f" [{max(b['idx'])}:{min(b['idx'])}]" if b["idx"] else ""
        ports.append(f"    {kw.get(b['dir'], 'input')} wire{rng} {base}")
    return ("// generated by scripts/gen_top_config.py from the LEF - blackbox only\n"
            f"(* blackbox *)\nmodule {module} (\n" + ",\n".join(ports) + "\n);\nendmodule\n")


def strip_sky130_stub(src, dst):
    s = open(src).read()
    s2, n = re.subn(r"\(\* blackbox \*\)\s*module sram_1rw1r_32_256_8_sky130.*?endmodule\s*", "", s, flags=re.S)
    if n != 1:
        sys.exit("BlockRAM_1KB.v: sky130 SRAM blackbox stub not found exactly once")
    open(dst, "w").write(s2)


# --------------------------------------------------------------------------- chip
# Pad ring (IHP sg13g2_io, 80 x 180 um pads, LibreLane Chip flow). One row per
# pad: (instance, cell, side, connection). The eFPGA_top config path (UART /
# bitbang, status LEDs) and the 16 fabric user IOs get pads; SelfWriteData /
# SelfWriteStrobe (the RV32IM's port later) are tied off, the A/B_config_C and
# Config_accessC observation buses stay internal. Side lists run in OpenROAD's
# placement order; the W_IO tiles sit on the west edge, I/O_top[1:0] at the
# bottom (Tile_X0Y8). User IOs are 30 mA bidirs: with 16 mA the pad pin's
# transition into the default output load was 2.58 ns vs 1.2 ns max (slow).
POWER_PADS = ("sg13g2_IOPadVdd", "sg13g2_IOPadVss", "sg13g2_IOPadIOVdd", "sg13g2_IOPadIOVss")
CHIP_PADS = (
    [("pad_iovdd_w", "sg13g2_IOPadIOVdd", "W", None)]
    + [(f"pad_io{i:02d}", "sg13g2_IOPadInOut30mA", "W", i) for i in range(0, 8)]
    + [("pad_vdd_w", "sg13g2_IOPadVdd", "W", None), ("pad_vss_w", "sg13g2_IOPadVss", "W", None)]
    + [(f"pad_io{i:02d}", "sg13g2_IOPadInOut30mA", "W", i) for i in range(8, 16)]
    + [("pad_iovss_w", "sg13g2_IOPadIOVss", "W", None)]
    + [("pad_vdd_s", "sg13g2_IOPadVdd", "S", None),
       ("pad_clk", "sg13g2_IOPadIn", "S", ("clk_PAD", "in", "clk")),
       ("pad_resetn", "sg13g2_IOPadIn", "S", ("resetn_PAD", "in", "resetn")),
       ("pad_rx", "sg13g2_IOPadIn", "S", ("rx_PAD", "in", "rx")),
       ("pad_sclk", "sg13g2_IOPadIn", "S", ("sclk_PAD", "in", "s_clk")),
       ("pad_sdata", "sg13g2_IOPadIn", "S", ("sdata_PAD", "in", "s_data")),
       ("pad_comactive", "sg13g2_IOPadOut16mA", "S", ("comactive_PAD", "out", "com_active")),
       ("pad_rxled", "sg13g2_IOPadOut16mA", "S", ("rxled_PAD", "out", "receive_led")),
       ("pad_vss_s", "sg13g2_IOPadVss", "S", None),
       ("pad_iovdd_s", "sg13g2_IOPadIOVdd", "S", None),
       ("pad_iovss_s", "sg13g2_IOPadIOVss", "S", None)]
    + [("pad_vdd_e", "sg13g2_IOPadVdd", "E", None), ("pad_vss_e", "sg13g2_IOPadVss", "E", None)]
    + [("pad_vdd_n", "sg13g2_IOPadVdd", "N", None), ("pad_vss_n", "sg13g2_IOPadVss", "N", None)]
)


def chip_top_v():
    sig = [p for p in CHIP_PADS if isinstance(p[3], tuple)]
    L = ["// generated by scripts/gen_top_config.py --chip - edit the generator, not this file",
         "// IHP SG13G2 test chip: eFPGA_top (eFPGA + 4 BlockRAM/SRAM + config logic)",
         "// inside an sg13g2_io pad ring. Pad supply pins MUST be wired here under",
         "// USE_POWER_PINS: LibreLane's Odb.SetPowerConnections creates the pads'",
         "// global power connections from this netlist (without it the pads sit on",
         "// no net and the core ring has nothing to connect to - first chip run).",
         "`default_nettype none", "module chip_top (",
         "`ifdef USE_POWER_PINS",
         "    inout wire VDD,", "    inout wire VSS,", "    inout wire IOVDD,", "    inout wire IOVSS,",
         "`endif",
         ",\n".join([f"    inout wire {p[3][0]}" for p in sig] + ["    inout wire [15:0] io_PAD"]),
         ");"]
    PWR = ("`ifdef USE_POWER_PINS\n        .iovdd(IOVDD), .iovss(IOVSS), .vdd(VDD), .vss(VSS)"
           "{sep}\n`endif\n        ")
    for n, c, _, conn in sig:
        L.append(f"    wire {conn[2]};")
    L += ["    wire [15:0] fab_out, fab_oe, fab_in;", ""]
    for n, c, _, conn in CHIP_PADS:
        if conn is None:
            L.append(f"    (* keep *) {c} {n} (\n        " + PWR.format(sep="") + ");")
        elif isinstance(conn, int):
            i = conn
            L.append(f"    {c} {n} (\n        " + PWR.format(sep=",") +
                     f".pad(io_PAD[{i}]), .c2p(fab_out[{i}]), .c2p_en(fab_oe[{i}]), .p2c(fab_in[{i}]));")
        elif conn[1] == "in":
            L.append(f"    {c} {n} (\n        " + PWR.format(sep=",") + f".pad({conn[0]}), .p2c({conn[2]}));")
        else:
            L.append(f"    {c} {n} (\n        " + PWR.format(sep=",") + f".pad({conn[0]}), .c2p({conn[2]}));")
    L += ["",
          "    // T_top is an output enable (1 = fabric drives the pin), as on Versal",
          "    eFPGA_top i_top (",
          "        .I_top(fab_out), .T_top(fab_oe), .O_top(fab_in),",
          "        .A_config_C(), .B_config_C(), .Config_accessC(),",
          "        .CLK(clk), .resetn(resetn),",
          "        .SelfWriteStrobe(1'b0), .SelfWriteData(32'h0),",
          "        .Rx(rx), .ComActive(com_active), .ReceiveLED(receive_led),",
          "        .s_clk(s_clk), .s_data(s_data)",
          "    );",
          "endmodule", "`default_nettype wire", ""]
    return "\n".join(L)


def chip_sdc():
    ins = " ".join(p[3][0] for p in CHIP_PADS if isinstance(p[3], tuple) and p[3][1] == "in" and p[0] != "pad_clk")
    outs = " ".join(p[3][0] for p in CHIP_PADS if isinstance(p[3], tuple) and p[3][1] == "out")
    return f"""# generated by scripts/gen_top_config.py --chip (structure after the IHP
# LibreLane template's chip_top.sdc, Apache-2.0). The clock is defined on the
# clock pad's core-side pin; IO delays are % of the period (IO_DELAY_CONSTRAINT).
current_design $::env(DESIGN_NAME)
set_units -time ns
create_clock [get_pins pad_clk/p2c] -name clk_PAD -period $::env(CLOCK_PERIOD)
set clocks [get_clocks clk_PAD]
set io_delay [expr $::env(CLOCK_PERIOD) * $::env(IO_DELAY_CONSTRAINT) / 100]
set_max_fanout $::env(MAX_FANOUT_CONSTRAINT) [current_design]
if {{ [info exists ::env(MAX_TRANSITION_CONSTRAINT)] }} {{ set_max_transition $::env(MAX_TRANSITION_CONSTRAINT) [current_design] }}
set in_ports [get_ports {{{ins} io_PAD[*]}}]
set_input_delay -min 0 -clock $clocks $in_ports
set_input_delay -max $io_delay -clock $clocks $in_ports
set_output_delay $io_delay -clock $clocks [get_ports {{{outs} io_PAD[*]}}]
set_load [expr $::env(OUTPUT_CAP_LOAD) / 1000.0] [all_outputs]
set_clock_uncertainty $::env(CLOCK_UNCERTAINTY_CONSTRAINT) $clocks
set_clock_transition $::env(CLOCK_TRANSITION_CONSTRAINT) $clocks
set_timing_derate -early [expr 1-[expr $::env(TIME_DERATING_CONSTRAINT) / 100]]
set_timing_derate -late [expr 1+[expr $::env(TIME_DERATING_CONSTRAINT) / 100]]
if {{ [info exists ::env(OPENLANE_SDC_IDEAL_CLOCKS)] && $::env(OPENLANE_SDC_IDEAL_CLOCKS) }} {{
    unset_propagated_clock [all_clocks]
}} else {{
    set_propagated_clock [all_clocks]
}}
"""


def chip_header(a, out, src, vfiles, die_w, die_h, off, core_w, core_h, q):
    top = os.path.join(src, "chip_top.v")
    open(top, "w").write(chip_top_v())
    sdc = os.path.join(out, "chip_top.sdc")
    open(sdc, "w").write(chip_sdc())
    bp = os.path.join(HERE, "ip", "sg13g2_bondpad_70x70_novias")
    for f in ("gds/bondpad_70x70_novias.gds", "lef/bondpad_70x70_novias.lef"):
        if not os.path.isfile(os.path.join(bp, f)):
            sys.exit(f"missing {bp}/{f} (bondpad from the IHP LibreLane template)")
    sides = {}
    for n, c, side, _ in CHIP_PADS:
        sides.setdefault(side, []).append(n)
    padlists = "\n".join(f"PAD_{dict(S='SOUTH', E='EAST', N='NORTH', W='WEST')[k]}: [{', '.join(v)}]"
                          for k, v in sides.items())
    return f"""meta:
  version: 3
  flow: Chip
  substituting_steps:
    # Magic reports overlaps in the pad ring that are expected (IHP template)
    Checker.IllegalOverlap: null
    # Magic DRC of the SRAM GDS reports millions of non-issues; KLayout
    # (precheck mode, below) is IHP's sign-off deck
    Magic.DRC: null
    Checker.MagicDRC: null
    # MANUAL_GLOBAL_PLACEMENTS (per-pin SRAM buffers at their pins) must act
    # BEFORE the post-GPL design repair: in the default order the repair saw
    # the buffers where global placement left them and inserted long-wire
    # buffers between them and the SRAM pins (A_DIN <- wireN, B_DOUT ->
    # wireN), which then stayed behind when the buffers moved to the pins.
    Odb.ManualGlobalPlacement: null
    "-OpenROAD.RepairDesignPostGPL": Odb.ManualGlobalPlacement

DESIGN_NAME: chip_top
VERILOG_FILES:
{chr(10).join('  - ' + q(f) for f in [top] + vfiles)}
VERILOG_DEFINES: []
PRIMARY_GDSII_STREAMOUT_TOOL: klayout

CLOCK_PORT: clk_PAD
CLOCK_NET: pad_clk/p2c
CLOCK_PERIOD: {a.clock_period}
PNR_SDC_FILE: {q(sdc)}
SIGNOFF_SDC_FILE: {q(sdc)}
FALLBACK_SDC: {q(sdc)}

VDD_NETS: [VDD]
GND_NETS: [VSS]

FP_SIZING: absolute
DIE_AREA: [0, 0, {die_w}, {die_h}]
CORE_AREA: [{off}, {off}, {round(off + core_w, 2)}, {round(off + core_h, 2)}]

{padlists}
PAD_BONDPAD_NAME: bondpad_70x70_novias
EXTRA_GDS: [{q(bp + '/gds/bondpad_70x70_novias.gds')}]
EXTRA_LEFS: [{q(bp + '/lef/bondpad_70x70_novias.lef')}]
IGNORE_DISCONNECTED_MODULES: [bondpad_70x70_novias]
# several pads per supply net
MAGIC_EXT_UNIQUE: notopports

# Fill: the PDK filler's fixed 1.5/2.0 um filler pitch cannot enter the
# fabric's narrow routing gaps (eFPGA windows failed MxFil.h 25 %);
# scripts/ihp_filler.py uses 0.42 um (M2-M4), 1.0 um (M5, global max 60 %),
# auto origin and shifted extra passes. Metal2 additionally needs the tiles'
# Metal2 density straps (fabric/Tile/include/pdn_m2_density.tcl).
KLAYOUT_FILLER_SCRIPT: {q(os.path.join(HERE, "scripts", "ihp_filler.py"))}

# core ring on TopMetal1/2 around the core, tied to the VDD/VSS pads
PDN_CORE_RING: true
PDN_CORE_RING_CONNECT_TO_PADS: true
PDN_CORE_RING_VWIDTH: 15
PDN_CORE_RING_HWIDTH: 15
PDN_CORE_RING_VSPACING: 5
PDN_CORE_RING_HSPACING: 5
PDN_ENABLE_PINS: false
"""


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--fabric", default=os.path.join(HERE, "fabric"))
    ap.add_argument("--pdk-root", default=os.environ.get("FAB_PDK_ROOT") or os.path.expanduser("~/.ciel"))
    ap.add_argument("--out", default=os.path.join(HERE, "build", "top"))
    ap.add_argument("--clock-period", type=float, default=20.0, help="ns (default 20)")
    ap.add_argument("--margin", type=float, default=80.0, help="west/south strip for config logic + IO pins (um)")
    # Narrow strips of standard-cell rows that no TopMetal1 strap crosses (pitch
    # 75.6 um, a VPWR+VGND pair spans 8.4 um) cannot get their Metal1 rails
    # connected -> PDN-0179. So a strip must be either row-free (narrower than
    # the 10 um row-cut halo on each side) or wide enough to always contain a
    # full strap pair: width - 2*10 >= 75.6 + 8.4 -> >= 104 um.
    # An 18 um row-free gap routed, but global routing overflowed in it (all
    # RAM_IO <-> SRAM/BlockRAM and Config_accessC nets squeeze through it):
    # GRT hotspots at the SRAM0/SRAM3 corners. 105 um = always-powered rows.
    ap.add_argument("--gap", type=float, default=105.0,
                    help="eFPGA east edge to SRAM column (um): < 20 (no rows) or >= 104 (rows + strap)")
    ap.add_argument("--edge", type=float, default=30.0, help="north margin (um)")
    ap.add_argument("--edge-east", type=float, default=8.0, help="east margin (um, < halo)")
    ap.add_argument("--pdn-halo", type=float, default=0.0,
                    help="PDN macro halo (um); must stay below the 10 um row-cut halo")
    ap.add_argument("--sram-inst", default="Inst_BlockRAM_{k}.memory_cell.u_sram",
                    help="flattened SRAM instance name pattern ({k} = 0..3)")
    ap.add_argument("--chip", action="store_true",
                    help="full chip: IHP pad ring around the eFPGA_top floorplan (LibreLane Chip flow)")
    ap.add_argument("--pad-margin", type=float, default=365.0,
                    help="chip mode: die edge to core (140 sealring offset + 180 pad + ~45 core ring)")
    a = ap.parse_args()
    if a.chip and a.out == os.path.join(HERE, "build", "top"):
        a.out = os.path.join(HERE, "build", "chip")

    fab = os.path.abspath(a.fabric)
    fv = os.path.join(fab, "Fabric", "macro", "final_views")
    e_lef, e_gds = os.path.join(fv, "lef", "eFPGA.lef"), os.path.join(fv, "gds", "eFPGA.gds")
    pdk = None
    # ciel: <root>/ihp-sg13g2/ihp-sg13g2/libs.ref ; plain checkout: <root>/ihp-sg13g2/libs.ref
    for c in (os.path.join(a.pdk_root, "ihp-sg13g2", "ihp-sg13g2"),
              os.path.join(a.pdk_root, "ihp-sg13g2"), a.pdk_root):
        if os.path.isdir(os.path.join(c, "libs.ref", "sg13g2_sram")):
            pdk = c
            break
    if not pdk:
        sys.exit(f"sg13g2_sram not found under {a.pdk_root} (set --pdk-root)")
    sr = os.path.join(pdk, "libs.ref", "sg13g2_sram")
    s_lef, s_gds = os.path.join(sr, "lef", SRAM + ".lef"), os.path.join(sr, "gds", SRAM + ".gds")
    s_lib = {k: os.path.join(sr, "lib", f"{SRAM}_{v}.lib") for k, v in
             (("*_typ_*", "typ_1p20V_25C"), ("*_slow_*", "slow_1p08V_125C"), ("*_fast_*", "fast_1p32V_m55C"))}
    for f in (e_lef, e_gds, s_lef, s_gds, *s_lib.values()):
        if not os.path.isfile(f):
            sys.exit(f"missing: {f}")

    ew, eh, epins = parse_lef(e_lef, "eFPGA")
    sw, sh, spins = parse_lef(s_lef, SRAM)
    for p in ("VPWR", "VGND"):
        if p not in epins:
            sys.exit(f"eFPGA LEF has no {p} pin - PDN assumptions do not hold")
    bad = [n for n, p in spins.items() if p["use"] == "SIGNAL" and any(r[1] > 2.0 for r in p["rects"][:1])]
    if bad:
        sys.exit(f"SRAM signal pins not on the south edge ({bad[:3]}...) - floorplan assumes they are")

    # --- floorplan ----------------------------------------------------------------
    ex, ey = snap(a.margin, SITE_X), snap(a.margin, SITE_Y)
    sx = snap(ex + ew + a.gap, SITE_X)
    die_w = round(sx + sw + a.edge_east, 2)
    die_h = round(ey + eh + a.edge, 2)
    srams = []
    for k in range(4):
        tiles = (f"Tile_X9Y{8 - 2 * k}_", f"Tile_X9Y{7 - 2 * k}_")
        ys = [r[3] for n, p in epins.items() if n.startswith(tiles) for r in p["rects"]]
        if not ys:
            sys.exit(f"no eFPGA pins for {tiles} - is the RAM_IO column at X9?")
        ys_lo = min(r[1] for n, p in epins.items() if n.startswith(tiles) for r in p["rects"])
        top = ey + max(ys)
        y = snap(top - sh, SITE_Y)
        srams.append(dict(k=k, inst=a.sram_inst.format(k=k), x=sx, y=y, band=(ey + ys_lo, top)))
    for s1, s2 in zip(srams, srams[1:]):
        if s2["y"] < s1["y"] + sh + 20:
            sys.exit("SRAM bands overlap - RAM_IO tiles shorter than expected; floorplan needs a rethink")

    # chip mode: the block floorplan above becomes the core, shifted by the pad
    # ring margin; macro instances live one level down (i_top.*)
    core_w, core_h = die_w, die_h
    # the core origin must sit on the site grid in x AND y (0.48 x 3.78 um ->
    # common multiple 30.24 um), else rows and fixed macros end up off-grid;
    # round UP so the core ring keeps its clearance to the pads
    grid = 30.24
    off = round(-(-a.pad_margin // grid) * grid, 2) if a.chip else 0.0
    pfx = "i_top." if a.chip else ""
    if a.chip:
        die_w, die_h = round(core_w + 2 * off, 2), round(core_h + 2 * off, 2)
        ex, ey = round(ex + off, 3), round(ey + off, 3)
        for s in srams:
            s["x"], s["y"] = round(s["x"] + off, 3), round(s["y"] + off, 3)
            s["inst"] = pfx + s["inst"]

    # --- sources -------------------------------------------------------------------
    out = os.path.abspath(a.out)
    src = os.path.join(out, "src")
    os.makedirs(src, exist_ok=True)
    fsrc = os.path.join(fab, "Fabric")
    vfiles = []
    for f in ("eFPGA_top.v", "eFPGA_Config.v", "ConfigFSM.v", "config_UART.v", "bitbang.v",
              "Frame_Data_Reg.v", "Frame_Select.v"):
        p = os.path.join(fsrc, f)
        if not os.path.isfile(p):
            sys.exit(f"missing source {p}")
        vfiles.append(p)
    strip_sky130_stub(os.path.join(fsrc, "BlockRAM_1KB.v"), os.path.join(src, "BlockRAM_1KB.v"))
    vfiles += [os.path.join(src, "BlockRAM_1KB.v"),
               os.path.join(HERE, "rtl", "asic", "ihp", "sram_1rw1r_32_256_8_sky130.v")]
    e_bb, s_bb = os.path.join(src, "eFPGA_bb.v"), os.path.join(src, SRAM + "_bb.v")
    open(e_bb, "w").write(blackbox("eFPGA", epins))
    open(s_bb, "w").write(blackbox(SRAM, spins))

    # --- PDN: default LibreLane grid + SRAM macro grid (TopMetal2 -> Metal4) ---------
    pdn = os.path.join(out, "pdn_top.tcl")
    open(pdn, "w").write(f"""# generated by scripts/gen_top_config.py
# LibreLane's default PDN (stdcell grid TM1/TM2 + rails, default macro grid
# with a TM1-TM2 connect -> eFPGA), plus a grid for the IHP SRAMs, whose
# VDD!/VDDARRAY!/VSS! pins are Metal4 stripes under TopMetal1/2.
source $::env(SCRIPTS_DIR)/openroad/common/pdn_cfg.tcl

define_pdn_grid \\
    -macro \\
    -cells {SRAM} \\
    -name sram_grid \\
    -starts_with POWER \\
    -halo "$::env(PDN_HORIZONTAL_HALO) $::env(PDN_VERTICAL_HALO)"

add_pdn_connect -grid sram_grid -layers "Metal4 TopMetal2"
""")

    # --- pin order: fabric IO west, Config_accessC north (east is SRAMs), config/clock south ---------
    pins = os.path.join(out, "pin_order.cfg")
    open(pins, "w").write("#W\nA_config_C.*\nB_config_C.*\nI_top.*\nO_top.*\nT_top.*\n"
                          "#N\nConfig_accessC.*\n"
                          "#S\nCLK\nresetn\nSelfWriteStrobe\nSelfWriteData.*\nRx\nComActive\nReceiveLED\ns_clk\ns_data\n")

    # --- config ----------------------------------------------------------------------
    def q(p):
        return '"' + p + '"'
    sram_insts = "\n".join(
        f"      {s['inst']}:\n        location: [{s['x']}, {s['y']}]\n        orientation: N" for s in srams)
    sram_rx = (pfx + a.sram_inst).replace(".", "\\\\.").replace("{k}", "[0-3]")
    vdd, gnd = ("VDD", "VSS") if a.chip else ("VPWR", "VGND")
    if a.chip:
        head = chip_header(a, out, src, vfiles, die_w, die_h, off, core_w, core_h, q)
    else:
        head = f"""DESIGN_NAME: eFPGA_top
VERILOG_FILES:
{chr(10).join('  - ' + q(f) for f in vfiles)}
VERILOG_DEFINES: []
CLOCK_PORT: CLK
CLOCK_PERIOD: {a.clock_period}

FP_SIZING: absolute
DIE_AREA: [0, 0, {die_w}, {die_h}]
IO_PIN_ORDER_CFG: {q(pins)}
PDN_ENABLE_PINS: true
"""
    cfg = f"""# generated by scripts/gen_top_config.py - edit the generator, not this file
{head}
# chip: 45 % - at 55 % the post-GRT hold buffers (pad inputs) could not be
# legalised (DPL-0033, 2 overlaps left)
PL_TARGET_DENSITY_PCT: {45 if a.chip else 55}

MACROS:
  eFPGA:
    gds: [{q(e_gds)}]
    lef: [{q(e_lef)}]
    vh: [{q(e_bb)}]
    instances:
      {pfx}eFPGA_inst:
        location: [{ex}, {ey}]
        orientation: N
  {SRAM}:
    gds: [{q(s_gds)}]
    lef: [{q(s_lef)}]
    vh: [{q(s_bb)}]
    lib:
{chr(10).join(f'      "{k}": [{q(v)}]' for k, v in s_lib.items())}
    instances:
{sram_insts}

PDN_CFG: {q(pdn)}
PDN_MULTILAYER: true
PDN_ENABLE_RAILS: true
PDN_CONNECT_MACROS_TO_GRID: true
PDN_MACRO_CONNECTIONS:
  - "{pfx.replace('.', '[.]')}eFPGA_inst {vdd} {gnd} VPWR VGND"
  - "{sram_rx} {vdd} {gnd} VDD! VSS!"
  - "{sram_rx} {vdd} {gnd} VDDARRAY! VSS!"
PDN_VERTICAL_LAYER: TopMetal1
PDN_HORIZONTAL_LAYER: TopMetal2
PDN_VWIDTH: 2.2
PDN_VSPACING: 4.0
PDN_VPITCH: 75.6
PDN_VOFFSET: 13.6
PDN_HWIDTH: 2.0
PDN_HSPACING: 4.0
PDN_HPITCH: 75.6
PDN_HOFFSET: 13.57
# pdngen keeps the stdcell grid out of macro+PDN halo, while rows are cut only
# at macro+FP_MACRO_*_HALO (10 um). With both at 10 the rows right next to
# the SRAMs got no TopMetal1 strap of one net -> PDN-0179 "Unable to repair
# all channels" (scripts/pdn_probe.sh: halo 10 -> 9 channels, halo 0 -> PDN
# clean, VPWR/VGND grid checks 0 errors). Keep PDN halo < row-cut halo.
PDN_HORIZONTAL_HALO: {a.pdn_halo}
PDN_VERTICAL_HALO: {a.pdn_halo}

# Hold: first full run had 71 reg-to-reg hold violations in the fast corner
# (worst -0.39 ns, config logic; the clock tree spans a 2.8 mm die and the
# post-CTS estimate missed the routed skew). Repair again after global routing
# and with a larger margin.
RUN_POST_GRT_RESIZER_TIMING: true
# Slew/cap: second full run had 279 max-slew pins, almost all SRAM inputs
# (liberty max_transition 0.595 ns; A_DIN up to 2.37 ns, the byte-replicated
# A_BM nets ~1.2 ns) and 64 fanout buffers over 0.3 pF. The pre-route repair
# underestimates the long SRAM-edge wires, so repair again after global
# routing, with more margin. SRAM inputs beyond the characterised slew are
# extrapolated timing (the SRAM liberty tables end at 0.5952 ns) - not
# acceptable for a tapeout. 30/25 % -> 35 left, 45/40 % -> 21 left (16 A_BM,
# 3 A_DIN, A_WEN/A_MEN marginal); more margin no longer helps (DPL stuck).
RUN_POST_GRT_DESIGN_REPAIR: true
DESIGN_REPAIR_MAX_SLEW_PCT: 45
DESIGN_REPAIR_MAX_CAP_PCT: 45
# chip: 2 SRAM2 din buffer inputs (u_pb_din g[29]/g[30]) still at 2.66 ns vs
# 2.51 ns limit in the slow corner after GRT repair at 40 %; the chip core
# (45 % density) has room for a stronger post-GRT repair than the block.
GRT_DESIGN_REPAIR_MAX_SLEW_PCT: {50 if a.chip else 40}
GRT_DESIGN_REPAIR_MAX_CAP_PCT: 40
# chip run 2026-10-13 (2nd): the 50 % slew margin did not help - the
# remaining slow-corner slews are X1 drivers on long single-sink nets
# (nor2_1 -> 1072 um routed, o21ai_1 -> 688 um under SRAM2 to its din
# buffers) that repair_design upsizes/buffers too little from the parasitic
# estimate. Force buffering of long wires instead (0 = off, the default).
DESIGN_REPAIR_MAX_WIRE_LENGTH: {400 if a.chip else 0}
GRT_DESIGN_REPAIR_MAX_WIRE_LENGTH: {400 if a.chip else 0}
PL_RESIZER_HOLD_SLACK_MARGIN: 0.25
GRT_RESIZER_HOLD_SLACK_MARGIN: 0.2
# Chip run 2026-10-13: hold clean in typ (ws +0.261 = the 0.25 margin) and
# slow, but -0.050 ns (3 paths) in nom_fast_1p32V_m40C - the repair evidently
# did not look at the fast corner. Name every corner explicitly so the
# resizer fixes hold where it is tightest.
RSZ_CORNERS:
  - nom_fast_1p32V_m40C
  - nom_typ_1p20V_25C
  - nom_slow_1p08V_125C

# KLayout DRC in IHP's precheck mode. Full mode flagged 4172 markers, ALL
# inside the PDK's own RM_IHPSG13_2P SRAM GDS (Sdiod.d/e on ContBar under the
# auto-generated nBuLay in COLDEC2/ROWREG6/..., Cnt.c.digibnd in the BITKIT
# cells); both rules sit in `unless PRECHECK_DRC` blocks of the deck. Setting
# the defines replaces the PDK dict, so its two entries are repeated.
KLAYOUT_DRC_DEFINES:
  no_recommended: "true"
  run_mode: deep
  precheck_drc: "true"

RT_MAX_LAYER: Metal5
# Allowed: the post-GRT hold repair re-runs global routing incrementally and,
# with this false, aborts on a single overflowed gcell (GRT-0232, total
# overflow 1). The real failure it was meant to catch (28k overflow) came from
# the 360 mm IO pins, fixed below. If detailed routing ever stalls again, set
# it false for one run to see the overflow before spending hours in DRT.
GRT_ALLOW_CONGESTION: true
# same OpenROAD-master workarounds as the tiles (see asic_gds_setup.sh):
# getArea() now returns DBU^2, so the default IO pin length comes out ~1e6x
# too long - first eFPGA_top run had 178 mm pins across the die (thousands of
# Metal2/Metal3 shorts). Min area 0.144 um2 / width 0.4 um = 0.36 um.
IO_PIN_V_LENGTH: 0.36
IO_PIN_H_LENGTH: 0.36
DIODE_ON_PORTS: none
"""
    cfg += sram_buffer_placements(srams, spins, pfx + a.sram_inst.rsplit(".", 1)[0], q)
    cfgp = os.path.join(out, "config.yaml")
    open(cfgp, "w").write(cfg)

    util = (ew * eh + 4 * sw * sh) / (die_w * die_h)
    print(f"eFPGA  {ew} x {eh} um at ({ex}, {ey})")
    for s in srams:
        print(f"SRAM{s['k']} {s['inst']:40s} at ({s['x']}, {s['y']}) N   "
              f"RAM_IO band y {s['band'][0]:.1f}..{s['band'][1]:.1f}")
    if a.chip:
        print(f"core   {core_w} x {core_h} um at ({off}, {off}); pads: {len(CHIP_PADS)} "
              f"({sum(1 for p in CHIP_PADS if p[1] in POWER_PADS)} power)")
    print(f"die    {die_w} x {die_h} um = {die_w * die_h / 1e6:.2f} mm2 (macros cover {util * 100:.0f} %)")
    print(f"wrote  {cfgp}")
    print(f"run:   cd {out} && librelane --pdk ihp-sg13g2 config.yaml")
    if not a.chip:
        print("       (add RUN_MAGIC_DRC: false to skip Magic's DRC of the SRAM GDS)")


if __name__ == "__main__":
    main()
