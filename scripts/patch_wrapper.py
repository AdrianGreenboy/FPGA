#!/usr/bin/env python3
"""Connect a user design to the FABulous-generated top_wrapper.v.

FABulous instantiates every bel of the fabric in user_design/top_wrapper.v but
leaves the user-design instance unconnected for anything but its demo design.
This script rewrites that instance:

  * io_in / io_out / io_oeb  -> IO_1_bidirectional_frame_config_pass O / I / T
  * optional BlockRAM #0 ports (if the user module declares them):
        bram0_rd_addr[7:0]  bram0_wr_addr[7:0]  bram0_wr_data[31:0]
        bram0_cfg[5:0]      bram0_rd_data[31:0]
    -> the RAM_IO pass bels of tiles X9Y8 / X9Y7, which eFPGA_top wires to
       Inst_BlockRAM_0 (rd_addr = FAB2RAM_A[7:0], wr_addr = FAB2RAM_A[15:8],
       wr_data = FAB2RAM_D[31:0], C0..C5 = FAB2RAM_C[5:0], rd_data = RAM2FAB_D[31:0]).
       Row Y8 carries the low half, row Y7 the high half (verified in eFPGA_top.v).

usage: patch_wrapper.py <top_wrapper.v> <user_design.v> <module_name>
"""
import re
import sys
from pathlib import Path

wrapper_p, design_p, module = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
w = wrapper_p.read_text()
d = design_p.read_text()

inst_re = re.compile(rf"^{module} user_design_i \(.*?\);\s*$", re.M)
if not inst_re.search(w):
    sys.exit(f"patch_wrapper: instance of {module} not found in {wrapper_p}")

conns = [".clk(clk)",
         ".io_in(IO_1_bidirectional_frame_config_pass_O)",
         ".io_out(IO_1_bidirectional_frame_config_pass_I)",
         ".io_oeb(IO_1_bidirectional_frame_config_pass_T)"]
extra = []

if re.search(r"\bbram0_wr_data\b", d):
    # bel name -> bus index, e.g. 'X9Y8.FAB2RAM_D0' -> 6
    out_idx, in_idx = {}, {}
    for m in re.finditer(r'BEL="(X\d+Y\d+\.\w+)"\s*\*\)\s*OutPass4_frame_config_mux\s+\w+\s*'
                         r'\(\.I0\(OutPass4_frame_config_mux_I0\[(\d+)\]\)', w):
        out_idx[m.group(1)] = int(m.group(2))
    for m in re.finditer(r'BEL="(X\d+Y\d+\.\w+)"\s*\*\)\s*InPass4_frame_config_mux\s+\w+\s*'
                         r'\(\.O0\(InPass4_frame_config_mux_O0\[(\d+)\]\)', w):
        in_idx[m.group(1)] = int(m.group(2))

    def out_bel(bel, signal, lsb, nbits=4):
        k = out_idx[bel]
        for b in range(nbits):
            extra.append(f"assign OutPass4_frame_config_mux_I{b}[{k}] = {signal}[{lsb + b}];")

    def in_bel(bel, signal, lsb):
        k = in_idx[bel]
        for b in range(4):
            extra.append(f"assign {signal}[{lsb + b}] = InPass4_frame_config_mux_O{b}[{k}];")

    try:
        for j in range(4):
            out_bel(f"X9Y8.FAB2RAM_D{j}", "bram0_wr_data", 4 * j)
            out_bel(f"X9Y7.FAB2RAM_D{j}", "bram0_wr_data", 16 + 4 * j)
            in_bel(f"X9Y8.RAM2FAB_D{j}", "bram0_rd_data", 4 * j)
            in_bel(f"X9Y7.RAM2FAB_D{j}", "bram0_rd_data", 16 + 4 * j)
        out_bel("X9Y8.FAB2RAM_A0", "bram0_rd_addr", 0)
        out_bel("X9Y8.FAB2RAM_A1", "bram0_rd_addr", 4)
        out_bel("X9Y7.FAB2RAM_A0", "bram0_wr_addr", 0)
        out_bel("X9Y7.FAB2RAM_A1", "bram0_wr_addr", 4)
        out_bel("X9Y8.FAB2RAM_C", "bram0_cfg", 0)
        out_bel("X9Y7.FAB2RAM_C", "bram0_cfg", 4, nbits=2)
    except KeyError as e:
        sys.exit(f"patch_wrapper: bel {e} not found in {wrapper_p} (fabric layout changed?)")

    extra = ["wire [7:0]  bram0_rd_addr, bram0_wr_addr;",
             "wire [31:0] bram0_wr_data, bram0_rd_data;",
             "wire [5:0]  bram0_cfg;"] + extra
    conns += [".bram0_rd_addr(bram0_rd_addr)", ".bram0_wr_addr(bram0_wr_addr)",
              ".bram0_wr_data(bram0_wr_data)", ".bram0_cfg(bram0_cfg)",
              ".bram0_rd_data(bram0_rd_data)"]

new_inst = f"{module} user_design_i ({', '.join(conns)});"
w = inst_re.sub(new_inst, w)
if extra:
    w = w.replace("endmodule //top_wrapper",
                  "// --- added by scripts/patch_wrapper.py ---\n" + "\n".join(extra)
                  + "\n\nendmodule //top_wrapper")
wrapper_p.write_text(w)
print(f"patch_wrapper: {module}: io" + (" + bram0" if extra else ""))
