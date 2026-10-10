`timescale 1ns / 1ps
`default_nettype none
// -----------------------------------------------------------------------------
// tb_fabric_probe : blk_macprobe bitstream on the raw fabric.
//   Drives O_top = {b[6:0], a[6:0], 2'b00}, expects I_top[15:2] = a*b.
//   Vectors: walking ones (a=1<<i, b=1<<j) + a few arbitrary products.
//   +hex=<blk_macprobe.hex>
// -----------------------------------------------------------------------------
module tb_fabric_probe;
    localparam integer MAXW = 4096;
    reg         CLK = 1'b0, resetn = 1'b1, strobe = 1'b0;
    reg  [31:0] wdata = 32'h0;
    reg  [15:0] O_top = 16'h0;
    wire [15:0] I_top, T_top;
    wire [31:0] A_cfg, B_cfg, C_acc;
    wire        ca, rl;
    always #20 CLK = ~CLK;

    eFPGA_top dut (.A_config_C(A_cfg), .B_config_C(B_cfg), .Config_accessC(C_acc),
                   .I_top(I_top), .O_top(O_top), .T_top(T_top), .CLK(CLK), .resetn(resetn),
                   .SelfWriteStrobe(strobe), .SelfWriteData(wdata), .Rx(1'b1),
                   .ComActive(ca), .ReceiveLED(rl), .s_clk(1'b0), .s_data(1'b0));

    reg [31:0] bs [0:MAXW-1];
    integer len = 0, k, errors = 0;
    reg [1023:0] hexf;

    task probe(input [6:0] a, input [6:0] b);
        reg [13:0] got, exp;
        begin
            O_top = {b, a, 2'b00};
            repeat (4) @(posedge CLK);   // combinational, settle generously
            got = I_top[15:2];
            exp = a * b;
            if (got !== exp) begin
                if (errors < 30) $display("  a=%0d b=%0d: got %h exp %h (xor %h)", a, b, got, exp, got ^ exp);
                errors = errors + 1;
            end
        end
    endtask

    integer i, j;
    initial begin
        if (!$value$plusargs("hex=%s", hexf)) begin $display("need +hex="); $finish; end
        for (k = 0; k < MAXW; k = k + 1) bs[k] = 32'hx;
        $readmemh(hexf, bs);
        for (k = 0; k < MAXW; k = k + 1) if (bs[k] !== 32'hx) len = k + 1;
        #100 resetn = 1'b0; #400 resetn = 1'b1;
        repeat (10) @(posedge CLK);
        for (k = 0; k < len; k = k + 1) begin
            @(posedge CLK) wdata <= bs[k];
            @(posedge CLK) strobe <= 1'b1;
            @(posedge CLK) strobe <= 1'b0;
            repeat (2) @(posedge CLK);
        end
        repeat (10) @(posedge CLK);

        for (i = 0; i < 7; i = i + 1)
            for (j = 0; j < 7; j = j + 1)
                probe(7'd1 << i, 7'd1 << j);
        probe(1, 0); probe(0, 1); probe(3, 3); probe(5, 27); probe(100, 100);
        probe(127, 127); probe(127, 1); probe(1, 127); probe(85, 37); probe(2, 83);

        if (errors == 0) $display("RESULT: PASS (fabric probe, %0d words)", len);
        else             $display("RESULT: FAIL (%0d mismatches)", errors);
        $finish;
    end
endmodule
`default_nettype wire
