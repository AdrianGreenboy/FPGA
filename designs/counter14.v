`default_nettype none
// Demo A: 14-bit counter. pin0 = sync reset, pin1 = enable, pins 2..15 = count
module counter14 (
    input  wire        clk,
    input  wire [15:0] io_in,
    output wire [15:0] io_out,
    output wire [15:0] io_oeb
);
    wire rst = io_in[0];
    wire en  = io_in[1];
    reg [13:0] ctr;
    always @(posedge clk)
        if (en) ctr <= rst ? 14'd0 : ctr + 1'b1;
    assign io_out = {ctr, 2'b00};
    assign io_oeb = 16'b0000_0000_0000_0011; // 1 = input (pin is not driven)
endmodule
`resetall
