`default_nettype none
// Demo B: 14-bit Fibonacci LFSR (x^14+x^13+x^12+x^2+1). pin0 = sync seed load, pin1 = enable
module lfsr14 (
    input  wire        clk,
    input  wire [15:0] io_in,
    output wire [15:0] io_out,
    output wire [15:0] io_oeb
);
    wire rst = io_in[0];
    wire en  = io_in[1];
    reg [13:0] s;
    wire fb = s[13] ^ s[12] ^ s[11] ^ s[1];
    always @(posedge clk)
        if (en) s <= rst ? 14'h0001 : {s[12:0], fb};
    assign io_out = {s, 2'b00};
    assign io_oeb = 16'b0000_0000_0000_0011;
endmodule
`resetall
