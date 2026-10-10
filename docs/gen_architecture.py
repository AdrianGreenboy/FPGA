#!/usr/bin/env python3
"""Generate docs/architecture.svg - full architecture of agfpga phase 0."""
E = []
W, H = 1680, 1270
INK = "#1f2937"; LINE = "#475569"; MUT = "#64748b"
ACC = "#b45309"          # amber: silicon-validated facts / the DSP58 fix
FILLS = dict(host="#eef2f7", ps="#e8eaf2", clk="#eef7ee", sc="#f3eee6",
             wrap="#faf3e3", fab="#f8fafc", cfg="#eef2fa", bram="#efeaf7",
             inset="#f8fafc", badge="#fff7ed")
COL = {0: ("#8fa3b8", "W_IO"), 3: ("#c0655c", "RegFile"), 6: ("#58a06c", "DSP"),
       9: ("#8f7fc0", "RAM_IO")}
LUTC = "#5b86c5"; TERM = "#dde3ea"

def esc(t): return t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
def text(x, y, s, size=12, color=INK, anchor="start", bold=False, mono=False, rotate=None):
    fam = "DejaVu Sans Mono, monospace" if mono else "Helvetica, Arial, sans-serif"
    w = ' font-weight="bold"' if bold else ""
    r = f' transform="rotate({rotate} {x} {y})"' if rotate is not None else ""
    E.append(f'<text x="{x}" y="{y}" font-size="{size}" fill="{color}" '
             f'text-anchor="{anchor}" font-family="{fam}"{w}{r}>{esc(s)}</text>')
def box(x, y, w, h, fill, title=None, stroke=LINE, dash=None, rx=8, tsize=14, tcolor=INK):
    d = f' stroke-dasharray="{dash}"' if dash else ""
    E.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" '
             f'fill="{fill}" stroke="{stroke}" stroke-width="1.4"{d}/>')
    if title: text(x + 12, y + 22, title, tsize, bold=True)
def arrow(x1, y1, x2, y2, label=None, color=LINE, dash=None, lsize=11,
          loff=(0, -6), width=1.6, anchor="middle"):
    d = f' stroke-dasharray="{dash}"' if dash else ""
    E.append(f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{color}" '
             f'stroke-width="{width}" marker-end="url(#ah)"{d}/>')
    if label:
        text((x1 + x2) / 2 + loff[0], (y1 + y2) / 2 + loff[1], label, lsize, MUT, anchor)
def lines(x, y, items, size=12, dy=17, color=INK, mono=False):
    for i, s in enumerate(items):
        text(x, y + i * dy, s, size, color, mono=mono)

# ---------------- header ----------------
text(40, 46, "agfpga — own embedded FPGA fabric (efpga_v0) emulated on AMD Versal", 24, bold=True)
text(40, 72, "Phase 0 architecture — FABulous-generated fabric + AXI4-Lite host interface on TE0950 / XCVE2302. "
             "Same fabric RTL goes to the ASIC (phase 2).", 13, MUT)
text(1640, 46, "2026-10-10", 12, MUT, anchor="end")
text(1640, 64, "silicon-validated", 12, ACC, anchor="end", bold=True)

# ---------------- left column: host ----------------
box(40, 100, 330, 190, FILLS["host"], "Host software")
lines(56, 146, [
    "efpga.py — Linux, /dev/mem mmio (32-bit!)",
    "efpga.h — bare-metal A72 (RV32IM later)",
    "efpga_xsdb.tcl / macprobe — JTAG selftest",
    "golden signatures from RTL sim (.expect)",
    "2.1 ms / bitstream from Linux, ~1.1 s via JTAG",
], 12, 18)
text(56, 272, "300+ runtime reconfigs, bit-exact", 12, ACC, bold=True)

box(40, 330, 330, 150, FILLS["ps"], "Versal PS")
lines(56, 376, [
    "2× Cortex-A72 — PetaLinux / bare-metal",
    "PMC + PLM — boot (PDI), JTAG DAP",
    "DDR via NoC (base design, untouched)",
], 12, 18)
text(56, 448, "M_AXI_FPD master → PL", 12, MUT, bold=True)

box(40, 520, 330, 128, FILLS["clk"], "Clocking / reset")
lines(56, 566, [
    "pl0_ref_clk 100 MHz → clk_wizard (MMCM)",
    "one fabric clock: AXI = config = user CLK",
    "25 MHz default (build-dependent, see note)",
    "proc_sys_reset ×2 (AXI / fabric domains)",
], 12, 18)

# ---------------- middle column ----------------
box(420, 330, 340, 90, FILLS["sc"], "AXI SmartConnect")
lines(436, 376, ["AXI4 → AXI4-Lite, 2 clock inputs", "4 KB window @ 0xA400_0000"], 12, 17)

box(420, 470, 340, 450, FILLS["wrap"], "efpga_axil — host wrapper (VHDL)")
text(436, 514, "register map (32-bit, AXI4-Lite)", 12, MUT, bold=True)
lines(436, 534, [
    "00 ID = 0xEF0A0001   04 CTRL",
    "08 STATUS            0C CFG_DATA (WO)",
    "10 CFG_COUNT         14 IO_IN",
    "18 IO_OUT            1C IO_OE",
    "20 SCRATCH           24 CYCLES",
    "28 IO_PULSE {count,mask}",
], 11.5, 17, mono=True)
lines(436, 660, [
    "SelfWrite sequencer: 5 clk / word",
    "  (data 2 · strobe 1 · quiet 2); the AXI",
    "  B-response paces software — no polling",
    "Isolation: CFG_MODE forces fabric inputs",
    "  to 0 and masks outputs while (re)loading",
    "IO_PULSE: inputs driven for EXACTLY N clk",
    "  → cycle-exact silicon vs. sim signatures",
    "Partial writes (WSTRB≠1111) → SLVERR",
], 12, 18)
text(436, 902, "hardened after the byte-wise-write silicon bug", 11, ACC)

arrow(150, 290, 150, 328, None)
text(96, 314, "mmio", 11, MUT)
arrow(300, 290, 300, 328, None, dash="5 4")
text(310, 312, "JTAG (xsdb → PMC DAP)", 11, MUT)
arrow(370, 400, 418, 375, None)
text(368, 364, "M_AXI_FPD", 11, MUT)
arrow(590, 420, 590, 468, "AXI4-Lite")
arrow(370, 584, 420, 584, None, dash="5 4")
text(378, 572, "25 MHz", 11, MUT)

# ---------------- fabric ----------------
FX, FY, FW, FH = 800, 100, 850, 810
box(FX, FY, FW, FH, FILLS["fab"], None, rx=10)
text(FX + 14, FY + 26, "eFPGA_top — fabric efpga_v0 (FABulous-generated RTL, untouched = ASIC source)", 15, bold=True)

# config plumbing strip
box(FX + 20, FY + 44, 300, 104, FILLS["cfg"], "ConfigFSM", tsize=13)
lines(FX + 34, FY + 86, [
    "sync word 0xFAB0_FAB1",
    "→ frame address → 16 row words",
    "desync flag bit 20",
], 11.5, 16)
box(FX + 340, FY + 44, 290, 104, FILLS["cfg"], "Frame registers / select", tsize=13)
lines(FX + 354, FY + 86, [
    "FrameData: 32 b × 16 rows",
    "FrameSelect: 20 frames / column",
    "→ writes tile config LATCHES",
], 11.5, 16)
box(FX + 650, FY + 44, 180, 104, FILLS["cfg"], "Bitstream", tsize=13)
lines(FX + 664, FY + 86, ["1806 words", "= 7.2 KB", "frame-based"], 11.5, 16)
arrow(760, 760, 798, 760, None)
text(700, 745, "SelfWriteData[31:0]", 11, MUT)
text(700, 778, "+ Strobe", 11, MUT)
E.append(f'<path d="M 800 762 C 810 762 812 200 818 180" stroke="{LINE}" stroke-width="1.4" fill="none" marker-end="url(#ah)"/>')

# tile grid
GX, GY, CS = FX + 60, FY + 196, 54
for r in range(10):
    for c in range(10):
        if r == 0 or r == 9:
            fill, lab = TERM, None
        elif c in COL:
            fill, lab = COL[c][0], None
        else:
            fill, lab = LUTC, None
        E.append(f'<rect x="{GX + c * CS}" y="{GY + r * CS}" width="{CS - 3}" height="{CS - 3}" '
                 f'rx="4" fill="{fill}" stroke="#ffffff" stroke-width="1.2" opacity="0.92"/>')
# DSP supertile brackets (rows 1-8 pair up)
for r in (1, 3, 5, 7):
    y = GY + r * CS + 4
    E.append(f'<rect x="{GX + 6 * CS + 4}" y="{y}" width="{CS - 11}" height="{2 * CS - 11}" '
             f'rx="4" fill="none" stroke="#2f6d44" stroke-width="1.6"/>')
# column labels
clabels = ["W_IO", "LUT", "LUT", "RF", "LUT", "LUT", "DSP", "LUT", "LUT", "RAM_IO"]
for c, lab in enumerate(clabels):
    text(GX + c * CS + (CS - 3) / 2, GY - 8, lab, 11, MUT, anchor="middle", bold=(c in COL))
text(GX - 10, GY + CS * 0.5 + 4, "N_term", 10.5, MUT, anchor="end")
text(GX - 10, GY + CS * 9.5 + 4, "S_term", 10.5, MUT, anchor="end")
text(GX - 10, GY + CS * 5, "8 logic", 10.5, MUT, anchor="end")
text(GX - 10, GY + CS * 5 + 13, "rows", 10.5, MUT, anchor="end")

# user IO arrows into W_IO column
arrow(760, GY + 4.0 * CS, GX - 4, GY + 4.0 * CS, None)
text(812, GY + 4.0 * CS - 12, "O_top[15:0] (in)", 10.5, MUT)
arrow(GX - 4, GY + 5.3 * CS, 760, GY + 5.3 * CS, None)
text(812, GY + 5.3 * CS + 18, "I_top/T_top (out/oe)", 10.5, MUT)
text(GX + 2, GY + 10 * CS + 16, "16 user IO bels (W_IO, 2 per row) — pins usable as in+out simultaneously (probe trick)", 10.5, MUT)

# BRAM stack
BX = GX + 10 * CS + 56
box(BX, GY + 40, 170, 300, FILLS["bram"], "4× BlockRAM", tsize=13)
for i in range(4):
    E.append(f'<rect x="{BX + 14}" y="{GY + 78 + i * 58}" width="142" height="44" rx="5" '
             f'fill="#ffffff" stroke="{LINE}" stroke-width="1.1"/>')
    text(BX + 24, GY + 96 + i * 58, f"BlockRAM_1KB #{i}", 11.5)
    text(BX + 24, GY + 112 + i * 58, "RAMB18 on Versal", 10.5, MUT)
arrow(GX + 10 * CS - 2, GY + 150, BX - 2, GY + 150, None)
arrow(BX - 2, GY + 200, GX + 10 * CS - 2, GY + 200, None)
lines(BX + 6, GY + 356, ["→ FAB2RAM A/D/C", "← RAM2FAB D[31:0]", "outside the tile grid,", "wired via RAM_IO bels;", "contents survive", "reconfiguration"], 10.5, 14, MUT)

# fabric stats
text(FX + 20, FY + FH - 36, "384 LUT4+FF  ·  8 RegFile 32×4  ·  4 MULADD 8×8+20-bit ACC  ·  16 user IO  ·  bitstream 1806 words", 12.5, bold=True)
text(FX + 20, FY + FH - 16, "emulation cost: 40 866 Versal LUTs (27.2 % of VE2302) ≈ 106 host LUTs per fabric LC — routing dominates (462 of ~480 cfg bits/tile)", 11.5, MUT)

# ---------------- insets ----------------
IY = 950
box(40, IY, 500, 290, FILLS["inset"], "Inside a LUT4AB tile (×48)")
box(60, IY + 44, 210, 200, "#ffffff", "switch matrix", tsize=12)
lines(74, IY + 86, ["462 config bits", "cus_mux21/41/81/161", "wires: N1/N2/N4, E/W,", "JUMP, GND/VCC", "", "transient comb. rings", "while reconfiguring →", "wrapper isolates fabric"], 11, 16)
for i in range(4):
    yy = IY + 54 + i * 46
    E.append(f'<rect x="{330}" y="{yy}" width="74" height="34" rx="4" fill="#ffffff" stroke="{LINE}"/>')
    text(367, yy + 21, "LUT4", 11, anchor="middle")
    E.append(f'<rect x="{428}" y="{yy}" width="46" height="34" rx="4" fill="#ffffff" stroke="{LINE}"/>')
    text(451, yy + 21, "FF", 11, anchor="middle")
    arrow(404, yy + 17, 426, yy + 17, None, width=1.2)
    arrow(272, yy + 17, 328, yy + 17, None, width=1.2)
text(402, IY + 250, "×8 per tile (A…H)", 11, MUT, anchor="middle")
text(60, IY + 272, "config cells = latches, written by frames — same RTL as the ASIC", 11, MUT)

box(560, IY, 520, 290, FILLS["inset"], "DSP tile — MULADD (×4, 2-tile supertile)")
lines(576, IY + 44, [], 11)
E.append(f'<rect x="580" y="{IY + 50}" width="120" height="110" rx="5" fill="#ffffff" stroke="{LINE}"/>')
lines(592, IY + 72, ["A[7:0]", "B[7:0]", "C[19:0]", "clr, CLK"], 11.5, 22, mono=True)
E.append(f'<rect x="730" y="{IY + 50}" width="130" height="110" rx="5" fill="#ffffff" stroke="{LINE}"/>')
lines(742, IY + 74, ["9×9 signed mult", "+ C / ACC add", "ACC register"], 11.5, 20)
E.append(f'<rect x="890" y="{IY + 70}" width="110" height="60" rx="5" fill="#ffffff" stroke="{LINE}"/>')
text(945, IY + 96, "Q[19:0]", 12, anchor="middle", mono=True)
text(945, IY + 114, "→ switch matrix", 10.5, MUT, anchor="middle")
arrow(700, IY + 105, 728, IY + 105, None)
arrow(860, IY + 100, 888, IY + 100, None)
text(576, IY + 186, "6 config bits: A_reg · B_reg · C_reg · ACC · signExtension · ACCout", 11.5, mono=True)
E.append(f'<rect x="576" y="{IY + 200}" width="488" height="72" rx="6" fill="{FILLS["badge"]}" stroke="{ACC}" stroke-width="1.4"/>')
lines(590, IY + 222, [
    "Vivado 2025.2.1 mis-synthesized the LUT multiplier (ghost carries in",
    "columns 1,2,6,8,10,12 — found with a 1898-product pin probe).",
    "Fix: (* use_dsp *) → real DSP58.  Silicon now 1898/1898 exact.",
], 11.5, 17, ACC)

box(1100, IY, 540, 290, FILLS["inset"], "Flows & silicon status")
chips = [("design.v", 1116), ("Yosys", 1222), ("nextpnr", 1306), ("bit_gen", 1398), (".hex/.bin", 1488)]
for name, x in chips:
    wch = {"design.v": 92, "Yosys": 70, "nextpnr": 78, "bit_gen": 76, ".hex/.bin": 86}[name]
    E.append(f'<rect x="{x}" y="{IY + 44}" width="{wch}" height="34" rx="6" fill="#ffffff" stroke="{LINE}"/>')
    text(x + wch / 2, IY + 65, name, 11.5, anchor="middle")
arrow(1208, IY + 61, 1220, IY + 61, None, width=1.2); arrow(1292, IY + 61, 1304, IY + 61, None, width=1.2)
arrow(1384, IY + 61, 1396, IY + 61, None, width=1.2); arrow(1474, IY + 61, 1486, IY + 61, None, width=1.2)
text(1116, IY + 98, "synth_fabulous · --uarch fabulous · frame bitstream → CFG_DATA over AXI (2.1 ms)", 11, MUT)
text(1116, IY + 126, "ASIC (phase 2): same fabric RTL → LibreLane / OpenROAD → GDSII (IHP SG13G2 / GF180)", 11.5)
E.append(f'<line x1="1116" y1="{IY + 140}" x2="1624" y2="{IY + 140}" stroke="{LINE}" stroke-width="0.7" stroke-dasharray="3 4"/>')
lines(1130, IY + 162, [
    "Silicon (TE0950): 300+ runtime reconfigs, 900/900 bit-exact",
    "Hard blocks PASS on 2 builds · MULADD 1898/1898 products",
    "Fmax per routed design: counter 50–75 · LFSR 75–100 MHz",
    "Host STA can't time configured paths → per-build lottery on",
    "long routes; remedy = pipeline (blocks14p: 240/240 PASS)",
], 11.5, 18)
for dy in (162, 180, 198):
    text(1114, IY + dy, "✓", 12, ACC, bold=True)

# legend chips for grid colors
LGX, LGY = FX + 60, FY + FH + 8
# (placed inside bottom margin of fabric? skip - column labels suffice)

svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" role="img" '
       f'aria-label="Architecture of the agfpga embedded FPGA emulated on AMD Versal">'
       f'<defs><marker id="ah" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" '
       f'markerHeight="7" orient="auto-start-reverse">'
       f'<path d="M 0 0 L 10 5 L 0 10 z" fill="{LINE}"/></marker></defs>'
       f'<rect width="{W}" height="{H}" fill="#ffffff"/>' + "".join(E) + "</svg>")
open(__file__.replace("gen_architecture.py", "architecture.svg"), "w").write(svg)
print("bytes:", len(svg))
