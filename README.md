# HERCOSS FPGA — own eFPGA fabric, phase 0: emulation on Versal

Goal: an ASIC SoC (own RV32IM + IP cores + **own FPGA fabric**). Phase 0 builds the
fabric with [FABulous](https://github.com/FPGA-Research/FABulous) and runs it *inside*
the Versal (TE0950 / VE2302), reconfigurable at runtime from the PS (later: from the RV32IM).

```
 A72 (Linux / bare metal) ──M_AXI_FPD──► SmartConnect ──► efpga_axil (VHDL) ──SelfWrite──► eFPGA_top (FABulous)
                                                         │  CTRL/STATUS/CFG_DATA          8×10 tiles, 384 LUT4+FF
                                                         └─ IO_IN / IO_OUT / IO_PULSE ──► 16 IO bels
```

## Fabric `efpga_v0`

| Resource | Count |
|---|---|
| Tiles (incl. N/S terminators) | 10 × 10, 8 logic rows |
| LUT4 + FF (`LUT4AB`, 48 tiles × 8) | 384 |
| RegFile 32×4 | 8 |
| MULADD 8×8 + 20-bit acc | 4 |
| BlockRAM_1KB (RAM_IO) | 4 |
| User IOs (W_IO, 2 per row) | 16 |
| Bitstream | 1806 words / 7224 bytes |

Definition: `fabric/fabric.csv` (default FABulous tile set, cut to 8 rows).

## Status

| Check | Result |
|---|---|
| FABulous fabric generation | ✔ |
| User designs `counter14`, `lfsr14` (Yosys + nextpnr + bitgen) | ✔ |
| `tb_fabric_reconfig`: raw fabric, A→B→A runtime reconfig, golden model every clock | **PASS** |
| `tb_axil`: VHDL wrapper (GHDL→Verilog) + fabric, AXI4-Lite, isolation, CFG_COUNT, IO_PULSE exact | **PASS** |
| Negative test (wrong bitstream must be detected) | **PASS** |
| `tb_axil`: partial writes (WSTRB≠1111) to CFG_DATA / IO_PULSE → SLVERR, not forwarded | **PASS** (old RTL fails it) |
| Vivado 2025.2.1 synth/impl/PDI for TE0950 (VE2302) | ✔ — see *Silicon results* |
| Silicon, JTAG (xsdb, `sw/efpga_xsdb.tcl`) | **PASS** — A→B→A ×3 |
| Silicon, Linux (A72, `/dev/mem`, `sw/efpga.py`) | **PASS** — 300 reconfigs, 900/900 bit-exact |

Silicon signatures (`IO_PULSE`: reset 1 clk, enable n clks; identical in sim):

| design | n=1 | n=1000 | n=16383 |
|---|---|---|---|
| counter14 | 0x0001 | 0x03e8 | 0x3fff |
| lfsr14 | 0x0002 | 0x1cda | 0x0001 (full period) |

## Silicon results (2026-10-10, TE0950 / XCVE2302-1LP, fabric clock 25 MHz)

| Metric | Value |
|---|---|
| Vivado utilisation (fabric + wrapper) | 40 866 / 150 272 CLB LUTs (27.2 %), 42 593 regs (14.2 %), 4 RAMB18, 0 DSP |
| Cost of emulation | ~106 Versal LUTs per fabric LC (routing dominates: 462 of ~480 config bits per LUT4AB tile) |
| Timing outside the fabric | met, worst +0.246 ns (CIPS M_AXI_FPD → SmartConnect) |
| Timing through the fabric | WNS −6206 ns — structural, meaningless; validated empirically instead |
| Hold | met everywhere (WHS +0.015 ns) |
| Selftest from Linux | 300 runtime reconfigurations (counter14 → lfsr14 → counter14 ×100), 900/900 signatures bit-exact |
| Reconfiguration time | 2.1 ms per 7.2 KB bitstream from the A72 (~3.4 MB/s); hardware floor 0.36 ms (5 clk/word @25 MHz) — AXI round-trip latency bound |
| Fabric clock measured | 25.02 MHz (CYCLES register) |

Open: real Fmax of the emulated fabric (clock sweep), BRAM / MULADD / RegFile not yet
exercised by any user design, configuration power during reconfiguration.

## Layout

```
fabric/                    FABulous project (generated RTL, untouched = ASIC source of truth)
designs/                   user designs for the fabric (counter14.v, lfsr14.v)
rtl/efpga_axil.vhd         AXI4-Lite host interface (VHDL-93/2008 clean)
rtl/fpga/                  FPGA model of the sky130 OpenRAM macro used by BlockRAM_1KB
scripts/compile_user_design.sh   design.v -> build/bitstreams/{bin,hex,h}
scripts/prepare_sources.sh       fabric -> build/src/{fpga.f,sim.f}
scripts/bin2words.py             .bin -> hex words / C array
sim/run_sim.sh             full regression (iverilog + GHDL)
vivado/add_efpga_to_bd.tcl add the subsystem to an OPEN Versal BD (CIPS untouched)
vivado/build_te0950.tcl    base .xpr -> copy -> +eFPGA -> PDI + XSA + reports
vivado/efpga.xdc           LUTLP-1 downgrade + ALLOW_COMBINATORIAL_LOOPS (fabric only)
sw/efpga.py                PetaLinux /dev/mem tool: info / load / selftest
sw/efpga_xsdb.tcl          same selftest over JTAG (programs the PDI, no Linux needed)
sw/efpga.h                 bare-metal driver (A72 now, RV32IM later)
```

## Register map (`efpga_axil`, 4 KB)

| Off | Name | Access | Description |
|---|---|---|---|
| 0x00 | ID | RO | `0xEF0A0001` |
| 0x04 | CTRL | RW | [0] CFG_MODE (isolate fabric, reset value 1), [1] CFG_RESET (pulse), [2] IN_SEL (0 = IO_IN, 1 = pin_i) |
| 0x08 | STATUS | RO | [0] CFG_BUSY, [1] CFG_MODE, [2] IN_SEL, [3] PULSE_BUSY |
| 0x0C | CFG_DATA | WO | one bitstream word; B response held until the 5-clk SelfWrite sequence ends. Full 32-bit writes only, partial → SLVERR |
| 0x10 | CFG_COUNT | RO | words since CFG_RESET |
| 0x14 | IO_IN | RW | [15:0] fabric inputs |
| 0x18 | IO_OUT | RO | [15:0] fabric outputs (0 while CFG_MODE) |
| 0x1C | IO_OE | RO | [15:0] 1 = fabric drives the pin |
| 0x20 | SCRATCH | RW | |
| 0x24 | CYCLES | RO | free-running fabric clock counter |
| 0x28 | IO_PULSE | RW | write `{COUNT[31:16], MASK[15:0]}`: inputs = IO_IN\|MASK for exactly COUNT clocks. Full 32-bit writes only, partial → SLVERR |

## Flow

```bash
# toolchain (tested): FABulous 2.2.0 (python 3.12 venv), yosys 0.66 (!), nextpnr-generic
# (git 861c57b, --uarch fabulous), iverilog 12, GHDL 4.1
scripts/compile_user_design.sh designs/counter14.v
scripts/compile_user_design.sh designs/lfsr14.v
sim/run_sim.sh                                   # ~4 min, ends with REGRESSION: PASS

# Vivado 2025.2.1 - ALWAYS through ./vivado.sh (strips the venv from PATH, see issue 7)
./vivado.sh -mode gui -source vivado/create_project_te0950.tcl   # empty project + CIPS
#   GUI: configure CIPS (M_AXI_FPD, PL0 100 MHz, 1 PL reset, NoC/DDR for Linux)
#   Tcl: source vivado/add_efpga_to_bd.tcl ; wrapper ; impl ; write_device_image
# or, from an existing working base project:
./vivado.sh -mode batch -source vivado/build_te0950.tcl -tclargs /path/base.xpr 25 4

# silicon over JTAG (no Linux)
xsdb sw/efpga_xsdb.tcl build/vivado/efpga_te0950.pdi \
     build/bitstreams/counter14.hex build/bitstreams/lfsr14.hex 0xA4000000 3

# silicon from PetaLinux (root; paste ONE command per line over UART)
python3 efpga.py --base 0xA4000000 info
python3 efpga.py --base 0xA4000000 selftest counter14.hex lfsr14.hex --loops 100
```

`add_efpga_to_bd.tcl` expects `M_AXI_FPD` and `pl0_ref_clk/pl0_resetn` on the CIPS. If
they are not enabled, it stops and tells you — enable them in the CIPS GUI. It adds an MMCM
(25 MHz), a reset block, a SmartConnect (or one MI on the existing SmartConnect), the
wrapper and assigns the address.

## Known issues / risks (honest list)

1. **Transient combinational rings during reconfiguration.** While frames of design A and B
   are mixed, switch matrices can close loops. Zero-delay simulation hangs (sim models get a
   0.2 ns mux delay); in silicon they oscillate until the breaking frame is written. The
   wrapper isolates the fabric (CFG_MODE) and user logic must be reset after loading. For the
   ASIC this also means extra dynamic power during configuration — worth measuring.
2. **Vivado STA is meaningless inside the fabric.** It times structural paths through
   unconfigured routing. Expect negative slack inside `u_efpga`; only wrapper↔fabric
   boundary paths are real. The fabric is validated empirically: selftest at 25 MHz, then
   sweep the clock (rebuild with `freq_mhz`) to find the real margin.
3. **Config cells are latches** (`config_latch`, same RTL as the ASIC). In Vivado they
   become LDCE gated by a decode of registered signals. **Silicon: 300 reconfigurations
   without a single failure** — keep as the first suspect if a future config fails.
4. **Vivado trims ~38k of ~79k config latches** whose outputs cannot reach any observable
   net (open `A/B_config_C` ports, unloaded branches). Safe by construction (no bitstream can
   observe them), but the emulation is not a 1:1 area model of the ASIC.
5. **Untested in this phase:** BRAM (FPGA model infers RAMB18), MULADD (mapped to LUTs,
   not DSP58), RegFile — no user design exercises them yet.
6. **Toolchain pinning:** yosys ≥ 0.67 dropped `share/fabulous` → compile fails with
   "IO_1_bidirectional_frame_config_pass is not part of the design". Use 0.66.
   FABulous project default PDK is IHP SG13G2; removed in `.FABulous/.env` for RTL work.

7. **Never launch Vivado from a shell with the FABulous venv active.** Lopper (PLM
   generation in `write_device_image`) picks up `.venv/bin/pcpp`, which dies under Vivado's
   `PYTHONHOME` ("No module named 'encodings'"). `./vivado.sh` strips it from PATH.
8. **Python register access must be 32-bit.** `struct.pack_into("<I", mmap, ...)` writes
   byte by byte → 4+ AXI writes per word; the old wrapper counted each one (CFG_COUNT
   = 5 × 1806 on silicon). Fixed twice: `efpga.py` uses `memoryview.cast("I")`, and the
   wrapper now rejects partial CFG_DATA / IO_PULSE writes with SLVERR.
9. **Disk space:** a fresh PetaLinux project needs 60–100 GB; keep it on `/data`.

## Next steps

- ~~Phase 0b: Vivado + silicon on TE0950~~ ✔ (2026-10-10). Remaining: clock sweep
  (50/75/100 MHz), power during reconfiguration, FIFO/DMA config path (2.1 → ~0.4 ms).
- User designs exercising BRAM, MULADD, RegFile.
- CPU_IO tile so the RV32IM sees the fabric as a bus peripheral / custom instruction unit.
- Phase 1: RV32IM + peripherals + eFPGA SoC in emulation; Phase 2: fabric sized for
  GF180 (wafer.space) or IHP SG13G2, LibreLane flow, latch-map tech file.
