`timescale 1ns / 1ps
`default_nettype none
// -----------------------------------------------------------------------------
// tb_fabric_expect : load a bitstream into the raw fabric and check IO_PULSE-style
// results against an expect file ("n value" per line, from a golden RTL sim).
//   +hex=<design.hex>  +expect=<design.expect>  [+other=<other.hex>]
// Sequence: load design, check all n; load <other> (if given); reload design,
// check all n again (memories now hold data of earlier runs -> must not matter).
// -----------------------------------------------------------------------------
module tb_fabric_expect;
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

    reg [31:0] bs_a [0:MAXW-1];
    reg [31:0] bs_b [0:MAXW-1];
    integer len_a = 0, len_b = 0, k, errors = 0, ne = 0;
    integer exp_n [0:31];
    reg [13:0] exp_v [0:31];
    reg [1023:0] hex_a, hex_b, exp_f;
    reg have_b;

    task load(input integer which, input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                @(posedge CLK) wdata <= (which == 0) ? bs_a[i] : bs_b[i];
                @(posedge CLK) strobe <= 1'b1;
                @(posedge CLK) strobe <= 1'b0;
                repeat (2) @(posedge CLK);
            end
            repeat (10) @(posedge CLK);
        end
    endtask

    task pulse(input [15:0] mask, input integer n);
        begin
            @(posedge CLK) O_top <= mask;
            repeat (n) @(posedge CLK);
            O_top <= 16'h0;
        end
    endtask

    task check_all(input [127:0] tag);
        integer i;
        begin
            for (i = 0; i < ne; i = i + 1) begin
                pulse(16'h0003, 1);
                repeat (3) @(posedge CLK);
                pulse(16'h0002, exp_n[i]);
                repeat (5) @(posedge CLK);
                if (I_top[15:2] !== exp_v[i]) begin
                    $display("  [%0s] n=%0d fabric=%h expected=%h", tag, exp_n[i], I_top[15:2], exp_v[i]);
                    errors = errors + 1;
                end else
                    $display("  [%0s] n=%0d -> %h ok", tag, exp_n[i], I_top[15:2]);
            end
        end
    endtask

    integer fd, rc, nn, vv;
    initial begin
        if (!$value$plusargs("hex=%s", hex_a) || !$value$plusargs("expect=%s", exp_f)) begin
            $display("usage: +hex=<file> +expect=<file> [+other=<file>]"); $finish;
        end
        have_b = $value$plusargs("other=%s", hex_b);
        for (k = 0; k < MAXW; k = k + 1) begin bs_a[k] = 32'hx; bs_b[k] = 32'hx; end
        $readmemh(hex_a, bs_a);
        if (have_b) $readmemh(hex_b, bs_b);
        for (k = 0; k < MAXW; k = k + 1) begin
            if (bs_a[k] !== 32'hx) len_a = k + 1;
            if (bs_b[k] !== 32'hx) len_b = k + 1;
        end
        fd = $fopen(exp_f, "r");
        while (!$feof(fd)) begin
            rc = $fscanf(fd, "%d %h\n", nn, vv);
            if (rc == 2) begin exp_n[ne] = nn; exp_v[ne] = vv; ne = ne + 1; end
        end
        $fclose(fd);
        $display("design %0d words, %0d expected values", len_a, ne);

        #100 resetn = 1'b0; #400 resetn = 1'b1;
        repeat (10) @(posedge CLK);
        load(0, len_a); check_all("first load");
        if (have_b) begin load(1, len_b); pulse(16'h0003, 1); pulse(16'h0002, 500); end
        load(0, len_a); check_all("reload   ");
        if (errors == 0) $display("RESULT: PASS (fabric matches golden)");
        else             $display("RESULT: FAIL (%0d mismatches)", errors);
        $finish;
    end
endmodule
`default_nettype wire
