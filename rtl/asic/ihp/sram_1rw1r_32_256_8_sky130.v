`default_nettype none
// -----------------------------------------------------------------------------
// sram_1rw1r_32_256_8_sky130 -- IHP SG13G2 implementation (ASIC build only)
//
// FABulous' BlockRAM_1KB instantiates the sky130 OpenRAM macro by this name.
// For the IHP chip the same name/interface is provided here and mapped onto
// the PDK's true dual-port macro RM_IHPSG13_2P_256x32_c2_bm_bist (256 x 32,
// per-bit write mask, 702.83 x 136.97 um):
//   port 0 (RW, used write-only by BlockRAM_1KB) -> macro port A, write
//   port 1 (R)                                   -> macro port B, read
// Semantics kept identical to the sky130 model / rtl/fpga model:
//   * active-low csb/web, byte write mask wmask0[b] -> bits 8b+7..8b
//   * synchronous read, data valid after the clk1 rising edge (1 cycle)
//   * dout0 is not used by BlockRAM_1KB and is driven from port A anyway
// IHP specifics (from the macro datasheet):
//   * A_DLY/B_DLY MUST be tied to 1
//   * BIST interface unused -> tied off, BIST_EN = 0
//   * NO conflict handling between ports: a read on B of the address being
//     written on A in the same cycle returns UNDEFINED data in silicon (the
//     behavioural model returns the old word). User designs must not read the
//     address they write in the same cycle (blocks14/blocks14p already don't).
// Do NOT add this file to the FPGA/Vivado source set (rtl/fpga has the model).
//
// Per-pin input drivers (ASIC synthesis only):
//   The macro's inputs are characterised up to 0.5952 ns transition (end of
//   its liberty tables). Its 372 pins sit along a 703 um south edge, and the
//   first hardened eFPGA_top left 21 of them at 0.7-1.0 ns after all resizer
//   repair (no room left to legalise more buffers). Every data/control input
//   therefore gets its own sg13g2_buf_4 (kept): the long wire moves in front
//   of the buffer, where std-cell limits apply, and each SRAM pin is driven by
//   one strong cell with a single load. A_BM in particular was 4 nets of 8
//   pins each (one per byte lane). Clocks are left to CTS. In simulation
//   (no SYNTHESIS define) the buffers are plain assigns.
// -----------------------------------------------------------------------------
module sram_1rw1r_32_256_8_sky130 #(
    parameter integer NUM_WMASKS = 4,
    parameter integer DATA_WIDTH = 32,
    parameter integer ADDR_WIDTH = 8,
    parameter integer RAM_DEPTH  = 1 << ADDR_WIDTH,
    parameter integer DELAY      = 3
) (
    input  wire                  clk0,
    input  wire                  csb0,
    input  wire                  web0,
    input  wire [NUM_WMASKS-1:0] wmask0,
    input  wire [ADDR_WIDTH-1:0] addr0,
    input  wire [DATA_WIDTH-1:0] din0,
    output wire [DATA_WIDTH-1:0] dout0,
    input  wire                  clk1,
    input  wire                  csb1,
    input  wire [ADDR_WIDTH-1:0] addr1,
    output wire [DATA_WIDTH-1:0] dout1
);
    wire [31:0] bm = {{8{wmask0[3]}}, {8{wmask0[2]}}, {8{wmask0[1]}}, {8{wmask0[0]}}};

    // buffered copies of every non-clock input that changes at run time
    wire [31:0] p_din, p_bm;
    wire [7:0]  p_addr0, p_addr1;
    wire        p_amen, p_awen, p_bmen, p_bren;
    wire [31:0] q_dout1;   // raw port-B read data, buffered onto dout1
    sram_pin_buf #(32) u_pb_din   (.a(din0),   .x(p_din));
    sram_pin_buf #(32) u_pb_bm    (.a(bm),     .x(p_bm));
    sram_pin_buf #(8)  u_pb_addr0 (.a(addr0),  .x(p_addr0));
    sram_pin_buf #(8)  u_pb_addr1 (.a(addr1),  .x(p_addr1));
    sram_pin_buf #(1)  u_pb_amen  (.a(~csb0),  .x(p_amen));
    sram_pin_buf #(1)  u_pb_awen  (.a(~web0),  .x(p_awen));
    sram_pin_buf #(1)  u_pb_bmen  (.a(~csb1),  .x(p_bmen));
    sram_pin_buf #(1)  u_pb_bren  (.a(~csb1),  .x(p_bren));
    // read data out: the macro's outputs are characterised up to 0.064 pF
    // load (end of its liberty table); one buffer per bit keeps the wire to
    // the fabric off the macro pin (first run: B_DOUT at 0.070 pF)
    sram_pin_buf #(32) u_pb_dout1 (.a(q_dout1), .x(dout1));

    RM_IHPSG13_2P_256x32_c2_bm_bist u_sram (
        // port A: write
        .A_CLK      (clk0),
        .A_MEN      (p_amen),
        .A_WEN      (p_awen),
        .A_REN      (1'b0),
        .A_ADDR     (p_addr0),
        .A_DIN      (p_din),
        .A_DLY      (1'b1),
        .A_DOUT     (dout0),
        .A_BM       (p_bm),
        .A_BIST_CLK (1'b0),
        .A_BIST_EN  (1'b0),
        .A_BIST_MEN (1'b0),
        .A_BIST_WEN (1'b0),
        .A_BIST_REN (1'b0),
        .A_BIST_ADDR(8'h00),
        .A_BIST_DIN (32'h0),
        .A_BIST_BM  (32'h0),
        // port B: read
        .B_CLK      (clk1),
        .B_MEN      (p_bmen),
        .B_WEN      (1'b0),
        .B_REN      (p_bren),
        .B_ADDR     (p_addr1),
        .B_DIN      (32'h0),
        .B_DLY      (1'b1),
        .B_DOUT     (q_dout1),
        .B_BM       (32'h0),
        .B_BIST_CLK (1'b0),
        .B_BIST_EN  (1'b0),
        .B_BIST_MEN (1'b0),
        .B_BIST_WEN (1'b0),
        .B_BIST_REN (1'b0),
        .B_BIST_ADDR(8'h00),
        .B_BIST_DIN (32'h0),
        .B_BIST_BM  (32'h0)
    );
endmodule

// One kept sg13g2_buf_4 per bit in ASIC synthesis, a wire in simulation.
module sram_pin_buf #(
    parameter integer W = 1
) (
    input  wire [W-1:0] a,
    output wire [W-1:0] x
);
`ifdef SYNTHESIS
    genvar i;
    generate
        for (i = 0; i < W; i = i + 1) begin : g
            (* keep *) sg13g2_buf_4 u_buf (.A(a[i]), .X(x[i]));
        end
    endgenerate
`else
    assign x = a;
`endif
endmodule
`default_nettype wire
