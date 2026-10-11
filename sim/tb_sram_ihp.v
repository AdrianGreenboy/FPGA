`timescale 1ns/1ps
`default_nettype none
// tb_sram_ihp: IHP SRAM wrapper (rtl/asic/ihp) vs the FPGA model (rtl/fpga,
// renamed sram_ref by sim/run_sram_ihp.sh) - random writes with byte masks and
// reads, same-cycle same-address read/write excluded (undefined on IHP silicon).
module tb_sram_ihp;
    reg clk = 0; always #5 clk = ~clk;
    reg csb0 = 1, web0 = 1, csb1 = 1;
    reg [3:0] wmask0 = 0; reg [7:0] addr0 = 0, addr1 = 0; reg [31:0] din0 = 0;
    wire [31:0] d0_i, d1_i, d0_r, d1_r;
    sram_1rw1r_32_256_8_sky130 dut (.clk0(clk), .csb0(csb0), .web0(web0), .wmask0(wmask0),
        .addr0(addr0), .din0(din0), .dout0(d0_i), .clk1(clk), .csb1(csb1), .addr1(addr1), .dout1(d1_i));
    sram_ref u_ref (.clk0(clk), .csb0(csb0), .web0(web0), .wmask0(wmask0),
        .addr0(addr0), .din0(din0), .dout0(d0_r), .clk1(clk), .csb1(csb1), .addr1(addr1), .dout1(d1_r));
    integer i, errs = 0, checks = 0, seed = 42;
    reg rd_valid = 0;
    initial begin
        // initialise every word (IHP model powers up X, the FPGA model 0)
        for (i = 0; i < 256; i = i + 1) begin
            @(negedge clk); csb0 = 0; web0 = 0; wmask0 = 4'hf; addr0 = i; din0 = 0; csb1 = 1;
        end
        @(negedge clk); csb0 = 1; web0 = 1;
        for (i = 0; i < 20000; i = i + 1) begin
            @(negedge clk);
            if (rd_valid) begin
                checks = checks + 1;
                if (d1_i !== d1_r) begin
                    errs = errs + 1;
                    if (errs <= 10) $display("MISMATCH it=%0d addr1=%h ihp=%h ref=%h", i, addr1, d1_i, d1_r);
                end
            end
            {csb0, web0} = ($random(seed) & 1) ? 2'b00 : 2'b11;
            wmask0 = $random(seed); addr0 = $random(seed); din0 = $random(seed);
            csb1 = ($random(seed) % 4) == 0;           // read 3 of 4 cycles
            addr1 = $random(seed);
            if (!csb0 && addr1 == addr0) addr1 = addr1 + 1;   // no same-address collision
            rd_valid = !csb1;
        end
        $display("%0d read checks, %0d mismatches", checks, errs);
        if (errs == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL");
        $finish;
    end
endmodule
`default_nettype wire
