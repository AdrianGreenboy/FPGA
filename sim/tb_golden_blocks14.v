`timescale 1ns / 1ps
`default_nettype none
// -----------------------------------------------------------------------------
// tb_golden_blocks14 : RTL golden model of designs/blocks14.v
//   blocks14 + FABulous primitive models (MULADD, RegFile_32x4 from the yosys
//   fabulous prims) + BlockRAM_1KB + the FPGA SRAM model.
//   Protocol identical to IO_PULSE selftest: rst+en for 1 clk, idle, en for n clk.
//   Writes build/sim/blocks14.expect ("n value" per line) and checks that the
//   result does not depend on idle gaps or on a pause inside the enable burst.
// -----------------------------------------------------------------------------
module tb_golden_blocks14;
    reg clk = 1'b0;
    always #20 clk = ~clk;

    reg  [15:0] io_in = 16'h0;
    wire [15:0] io_out, io_oeb;
    wire [7:0]  ra, wa;
    wire [31:0] wd, rd;
    wire [5:0]  cfg;

    blocks14 dut (.clk(clk), .io_in(io_in), .io_out(io_out), .io_oeb(io_oeb),
                  .bram0_rd_addr(ra), .bram0_wr_addr(wa), .bram0_wr_data(wd),
                  .bram0_cfg(cfg), .bram0_rd_data(rd));
    BlockRAM_1KB bram (.clk(clk), .rd_addr(ra), .rd_data(rd), .wr_addr(wa), .wr_data(wd),
                       .C0(cfg[0]), .C1(cfg[1]), .C2(cfg[2]), .C3(cfg[3]), .C4(cfg[4]), .C5(cfg[5]));

    task pulse(input [15:0] mask, input integer n);
        begin
            @(negedge clk) io_in = mask;
            repeat (n) @(negedge clk);
            io_in = 16'h0;
        end
    endtask

    // garbage in both memories, as left behind by a previous user design
    task scramble;
        integer i;
        begin
            for (i = 0; i < 32; i = i + 1)  dut.u_rf.mem[i] = $random;
            for (i = 0; i < 256; i = i + 1) bram.memory_cell.mem[i] = $random;
        end
    endtask

    // run: reset, gap g1, enable n (optionally split n1 + pause p + rest), gap, read
    reg [13:0] r;
    task run(input integer n, input integer g1, input integer split, input integer p);
        begin
            scramble;
            pulse(16'h0003, 1);
            repeat (g1) @(negedge clk);
            if (split > 0 && split < n) begin
                pulse(16'h0002, split);
                repeat (p) @(negedge clk);
                pulse(16'h0002, n - split);
            end else
                pulse(16'h0002, n);
            repeat (5) @(negedge clk);
            r = io_out[15:2];
        end
    endtask

    // mutation hooks (sim/run_sim.sh checks that every block changes the signature)
`ifdef MUT_BRAM  initial force rd = 32'h0;            `endif
`ifdef MUT_RF    initial force dut.rf_q = 4'h0;       `endif
`ifdef MUT_MAC   initial force dut.acc = 20'h0;       `endif

    integer ns [0:5];
    integer k, fd, errors = 0;
    reg [13:0] ref_v;
    initial begin
        ns[0] = 1; ns[1] = 2; ns[2] = 3; ns[3] = 37; ns[4] = 1000; ns[5] = 16383;
        fd = $fopen("blocks14.expect", "w");
        for (k = 0; k < 6; k = k + 1) begin
            run(ns[k], 1, 0, 0);   ref_v = r;
            run(ns[k], 13, 0, 0);
            if (r !== ref_v) begin $display("FAIL n=%0d gap dependence %h vs %h", ns[k], r, ref_v); errors = errors + 1; end
            run(ns[k], 4, ns[k] / 2, 9);
            if (r !== ref_v) begin $display("FAIL n=%0d pause dependence %h vs %h", ns[k], r, ref_v); errors = errors + 1; end
            if (^ref_v === 1'bx) begin $display("FAIL n=%0d X in result", ns[k]); errors = errors + 1; end
            $display("blocks14 n=%0d -> %h", ns[k], ref_v);
            $fdisplay(fd, "%0d %04x", ns[k], ref_v);
        end
        $fclose(fd);
        if (errors == 0) $display("RESULT: PASS (golden blocks14, gap/pause invariant)");
        else             $display("RESULT: FAIL (%0d)", errors);
        $finish;
    end
endmodule
`default_nettype wire
