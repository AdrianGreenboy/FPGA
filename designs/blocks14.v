`default_nettype none
// -----------------------------------------------------------------------------
// blocks14 : exercises the hard blocks of efpga_v0 in one design
//   - MULADD (DSP tile)      : 20-bit accumulator  acc += c * (c ^ 0xA5)
//   - RegFile_32x4           : write mem[c] = c[3:0]^c[7:4], read back mem[c-1]
//   - BlockRAM_1KB #0 (RAM_IO rows Y8/Y7): write mem[c] = c ^ 0x3C, read mem[c-1]
// All three feed a 14-bit MISR; the MISR is the output (pins 15..2).
//   pin0 = sync reset, pin1 = enable (same protocol as counter14 / lfsr14)
//
// Determinism rules (the fabric keeps BRAM/RegFile contents across
// reconfigurations, and the clock keeps running while en=0):
//   * MULADD has no clock enable -> operands are forced to 0 while en=0, so
//     the accumulator holds; clr = reset.
//   * Memories are only read at addresses written since the last reset; the
//     first reads after reset are masked by a small valid counter.
//   * The BRAM read is synchronous: the data used at a step edge was read at
//     the previous clock edge. During a pause that edge is a pause edge, so the
//     read address must equal the one of the last step cycle: rd_addr = c-1
//     while en=1, c-2 while en=0. The result is then independent of pauses.
// Golden values come from RTL simulation of this file (sim/tb_golden_blocks14.v).
// -----------------------------------------------------------------------------
module blocks14 (
    input  wire        clk,
    input  wire [15:0] io_in,
    output wire [15:0] io_out,
    output wire [15:0] io_oeb,
    // BlockRAM_1KB #0 (eFPGA_top Inst_BlockRAM_0), via the RAM_IO pass bels
    output wire [ 7:0] bram0_rd_addr,
    output wire [ 7:0] bram0_wr_addr,
    output wire [31:0] bram0_wr_data,   // [20] = write enable (active high)
    output wire [ 5:0] bram0_cfg,       // C0..C5 = 0: 32-bit ports, no extra reg
    input  wire [31:0] bram0_rd_data    // 1-cycle synchronous read
);
    wire rst = io_in[0];
    wire en  = io_in[1];
    wire step = en & ~rst;

    reg  [ 7:0] c;          // address / data counter
    reg  [ 2:0] valid;      // saturating count of steps since reset
    reg  [13:0] sig;        // MISR

    always @(posedge clk) begin
        if (en) begin
            if (rst) begin
                c     <= 8'd0;
                valid <= 3'd0;
            end else begin
                c <= c + 8'd1;
                if (valid != 3'd7) valid <= valid + 3'd1;
            end
        end
    end

    // ---------------- MULADD: accumulator mode, registered output ------------
    wire [ 7:0] mul_a = step ? c : 8'd0;
    wire [ 7:0] mul_b = step ? (c ^ 8'hA5) : 8'd0;
    wire [19:0] acc;
    MULADD #(.A_reg(1'b0), .B_reg(1'b0), .C_reg(1'b0), .ACC(1'b1),
             .signExtension(1'b0), .ACCout(1'b1)) u_mac (
        .A7(mul_a[7]), .A6(mul_a[6]), .A5(mul_a[5]), .A4(mul_a[4]),
        .A3(mul_a[3]), .A2(mul_a[2]), .A1(mul_a[1]), .A0(mul_a[0]),
        .B7(mul_b[7]), .B6(mul_b[6]), .B5(mul_b[5]), .B4(mul_b[4]),
        .B3(mul_b[3]), .B2(mul_b[2]), .B1(mul_b[1]), .B0(mul_b[0]),
        .C19(1'b0), .C18(1'b0), .C17(1'b0), .C16(1'b0), .C15(1'b0),
        .C14(1'b0), .C13(1'b0), .C12(1'b0), .C11(1'b0), .C10(1'b0),
        .C9(1'b0), .C8(1'b0), .C7(1'b0), .C6(1'b0), .C5(1'b0),
        .C4(1'b0), .C3(1'b0), .C2(1'b0), .C1(1'b0), .C0(1'b0),
        .Q19(acc[19]), .Q18(acc[18]), .Q17(acc[17]), .Q16(acc[16]), .Q15(acc[15]),
        .Q14(acc[14]), .Q13(acc[13]), .Q12(acc[12]), .Q11(acc[11]), .Q10(acc[10]),
        .Q9(acc[9]), .Q8(acc[8]), .Q7(acc[7]), .Q6(acc[6]), .Q5(acc[5]),
        .Q4(acc[4]), .Q3(acc[3]), .Q2(acc[2]), .Q1(acc[1]), .Q0(acc[0]),
        .clr(rst), .CLK(clk)
    );

    // ---------------- RegFile_32x4: combinational read of mem[c-1] -----------
    wire [4:0] rf_wa = c[4:0];
    wire [4:0] rf_ra = c[4:0] - 5'd1;
    wire [3:0] rf_d  = c[3:0] ^ c[7:4];
    wire [3:0] rf_q, rf_unused;
    RegFile_32x4 #(.AD_reg(1'b0), .BD_reg(1'b0)) u_rf (
        .D0(rf_d[0]), .D1(rf_d[1]), .D2(rf_d[2]), .D3(rf_d[3]),
        .W_ADR0(rf_wa[0]), .W_ADR1(rf_wa[1]), .W_ADR2(rf_wa[2]),
        .W_ADR3(rf_wa[3]), .W_ADR4(rf_wa[4]), .W_en(step),
        .AD0(rf_q[0]), .AD1(rf_q[1]), .AD2(rf_q[2]), .AD3(rf_q[3]),
        .A_ADR0(rf_ra[0]), .A_ADR1(rf_ra[1]), .A_ADR2(rf_ra[2]),
        .A_ADR3(rf_ra[3]), .A_ADR4(rf_ra[4]),
        .BD0(rf_unused[0]), .BD1(rf_unused[1]), .BD2(rf_unused[2]), .BD3(rf_unused[3]),
        .B_ADR0(1'b0), .B_ADR1(1'b0), .B_ADR2(1'b0), .B_ADR3(1'b0), .B_ADR4(1'b0),
        .CLK(clk)
    );

    // ---------------- BlockRAM #0: write mem[c], read mem[c-1] ---------------
    assign bram0_cfg     = 6'b000000;
    assign bram0_wr_addr = c;
    assign bram0_rd_addr = en ? (c - 8'd1) : (c - 8'd2);
    assign bram0_wr_data = {11'd0, step, 12'd0, c ^ 8'h3C};
    wire [7:0] bram_q = bram0_rd_data[7:0];

    // ---------------- MISR -----------------------------------------------------
    wire rf_ok   = (valid >= 3'd1);
    wire bram_ok = (valid >= 3'd2);          // data = mem[c-2], written 2 steps ago
    wire [13:0] in_vec = acc[13:0]
                       ^ {acc[19:14], 8'd0}
                       ^ {10'd0, rf_ok ? rf_q : 4'd0}
                       ^ {bram_ok ? bram_q : 8'd0, 6'd0};
    wire fb = sig[13] ^ sig[12] ^ sig[11] ^ sig[1];
    always @(posedge clk)
        if (en) sig <= rst ? 14'd0 : ({sig[12:0], fb} ^ in_vec);

    assign io_out = {sig, 2'b00};
    assign io_oeb = 16'b0000_0000_0000_0011;
endmodule
`default_nettype wire
