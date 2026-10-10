`default_nettype none
// -----------------------------------------------------------------------------
// blk_macprobe : combinational probe of the MULADD hard block.
//   A = {1'b0, io_in[8:2]}   (7-bit operand from the IO_IN register)
//   B = {1'b0, io_in[15:9]}  (7-bit operand)
//   io_out[15:2] = Q[13:0] = A * B   (MULADD fully combinational: no regs,
//                                     no accumulator, C = 0, unsigned)
// The wrapper's IO_IN register and IO_OUT readback are independent nets, so a
// pin can be used as input and output at the same time. Max product
// 127*127 = 0x3F01 fits in 14 bits. Software just writes IO_IN and reads IO_OUT.
// -----------------------------------------------------------------------------
module blk_macprobe (
    input  wire        clk,
    input  wire [15:0] io_in,
    output wire [15:0] io_out,
    output wire [15:0] io_oeb
);
    wire [7:0] a = {1'b0, io_in[8:2]};
    wire [7:0] b = {1'b0, io_in[15:9]};
    wire [19:0] q;

    MULADD #(.A_reg(1'b0), .B_reg(1'b0), .C_reg(1'b0), .ACC(1'b0),
             .signExtension(1'b0), .ACCout(1'b0)) u_mac (
        .A7(a[7]), .A6(a[6]), .A5(a[5]), .A4(a[4]),
        .A3(a[3]), .A2(a[2]), .A1(a[1]), .A0(a[0]),
        .B7(b[7]), .B6(b[6]), .B5(b[5]), .B4(b[4]),
        .B3(b[3]), .B2(b[2]), .B1(b[1]), .B0(b[0]),
        .C19(1'b0), .C18(1'b0), .C17(1'b0), .C16(1'b0), .C15(1'b0),
        .C14(1'b0), .C13(1'b0), .C12(1'b0), .C11(1'b0), .C10(1'b0),
        .C9(1'b0), .C8(1'b0), .C7(1'b0), .C6(1'b0), .C5(1'b0),
        .C4(1'b0), .C3(1'b0), .C2(1'b0), .C1(1'b0), .C0(1'b0),
        .Q19(q[19]), .Q18(q[18]), .Q17(q[17]), .Q16(q[16]), .Q15(q[15]),
        .Q14(q[14]), .Q13(q[13]), .Q12(q[12]), .Q11(q[11]), .Q10(q[10]),
        .Q9(q[9]), .Q8(q[8]), .Q7(q[7]), .Q6(q[6]), .Q5(q[5]),
        .Q4(q[4]), .Q3(q[3]), .Q2(q[2]), .Q1(q[1]), .Q0(q[0]),
        .clr(1'b0), .CLK(clk)
    );

    assign io_out = {q[13:0], 2'b00};
    assign io_oeb = 16'h0000;
endmodule
`default_nettype wire
