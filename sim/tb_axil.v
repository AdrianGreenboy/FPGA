`timescale 1ns / 1ps
`default_nettype none
// -----------------------------------------------------------------------------
// tb_axil : full host path  AXI4-Lite -> efpga_axil (VHDL, via ghdl --synth) -> eFPGA
//   - ID / SCRATCH / byte strobes
//   - isolation in CFG_MODE (IO_OUT masked, fabric inputs forced 0)
//   - bitstream streaming through CFG_DATA, CFG_COUNT check
//   - A (counter14) -> B (lfsr14) -> A, each checked two ways:
//       * every clock against a golden model fed by the wrapper's fabric inputs
//       * frozen readback over AXI (IO_IN.en = 0) against the golden value
// -----------------------------------------------------------------------------
module tb_axil;
    localparam integer MAXW = 4096;

    reg aclk = 1'b0, aresetn = 1'b0;
    always #20 aclk = ~aclk;          // 25 MHz

    reg  [7:0]  awaddr = 0, araddr = 0;
    reg         awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    reg  [31:0] wdata = 0;
    reg  [3:0]  wstrb = 4'hF;
    wire        awready, wready, bvalid, arready, rvalid;
    wire [1:0]  bresp, rresp;
    wire [31:0] rdata;
    wire [15:0] pin_o, pin_oe;

    efpga_axil dut (
        .aclk(aclk), .aresetn(aresetn),
        .s_axi_awaddr(awaddr), .s_axi_awprot(3'b000), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arprot(3'b000), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .pin_i(16'h0000), .pin_o(pin_o), .pin_oe(pin_oe)
    );

    integer errors = 0;
    task check(input [255:0] what, input [31:0] got, input [31:0] exp);
        begin
            if (got !== exp) begin
                $display("  FAIL %0s: got %h exp %h", what, got, exp);
                errors = errors + 1;
            end
        end
    endtask

    // ---------------- AXI4-Lite master (AW and W issued together) -------------
    task axi_write(input [7:0] a, input [31:0] d, input [3:0] s);
        begin
            axi_write_resp(a, d, s, 2'b00);
        end
    endtask

    task axi_write_resp(input [7:0] a, input [31:0] d, input [3:0] s, input [1:0] exp_resp);
        reg aw_done, w_done;
        begin
            @(posedge aclk);
            awaddr <= a; awvalid <= 1'b1; wdata <= d; wstrb <= s; wvalid <= 1'b1; bready <= 1'b1;
            aw_done = 0; w_done = 0;
            while (!(aw_done && w_done)) begin
                @(posedge aclk);
                if (awvalid && awready) begin awvalid <= 1'b0; aw_done = 1; end
                if (wvalid && wready)   begin wvalid  <= 1'b0; w_done  = 1; end
            end
            while (!bvalid) @(posedge aclk);
            @(posedge aclk);
            bready <= 1'b0;
            if (bresp !== exp_resp) begin
                $display("  FAIL addr %h strb %b: bresp=%b expected %b", a, s, bresp, exp_resp);
                errors = errors + 1;
            end
        end
    endtask

    task axi_read(input [7:0] a, output [31:0] d);
        begin
            @(posedge aclk);
            araddr <= a; arvalid <= 1'b1; rready <= 1'b1;
            @(posedge aclk);
            while (!arready) @(posedge aclk);
            arvalid <= 1'b0;
            while (!rvalid) @(posedge aclk);
            d = rdata;
            @(posedge aclk);
            rready <= 1'b0;
        end
    endtask

    // ---------------- golden models on the real fabric inputs ----------------
    wire [15:0] fin  = dut.fab_o_top;    // what the wrapper presents to the fabric
    wire [15:0] fout = dut.fab_i_top;    // raw fabric outputs
    reg  [13:0] g_ctr = 0, g_lfsr = 1;
    reg         mode_lfsr = 0, live_check = 0;
    always @(posedge aclk) if (fin[1]) begin
        g_ctr  <= fin[0] ? 14'd0 : g_ctr + 1'b1;
        g_lfsr <= fin[0] ? 14'h0001 : {g_lfsr[12:0], g_lfsr[13] ^ g_lfsr[12] ^ g_lfsr[11] ^ g_lfsr[1]};
    end
    integer live_cycles = 0;
    always @(negedge aclk) if (live_check) begin
        live_cycles = live_cycles + 1;
        if (fout[15:2] !== (mode_lfsr ? g_lfsr : g_ctr)) begin
            if (errors < 10) $display("  FAIL live cyc %0d: fabric %h gold %h", live_cycles,
                                      fout[15:2], mode_lfsr ? g_lfsr : g_ctr);
            errors = errors + 1;
        end
    end

    // ---------------- bitstreams ----------------
    reg [31:0] bs_a [0:MAXW-1];
    reg [31:0] bs_b [0:MAXW-1];
    integer len_a = 0, len_b = 0, k;

    task configure(input integer which, input integer n, input [127:0] tag);
        reg [31:0] r;
        integer i, t0;
        begin
            axi_write(8'h04, 32'h0000_0003, 4'hF);         // CFG_MODE=1, CFG_RESET
            axi_read(8'h18, r); check({tag, " IO_OUT masked"}, r, 32'h0);
            check({tag, " fabric inputs isolated"}, {16'h0, fin}, 32'h0);
            t0 = $time;
            for (i = 0; i < n; i = i + 1)
                axi_write(8'h0C, which == 0 ? bs_a[i] : bs_b[i], 4'hF);
            axi_read(8'h10, r); check({tag, " CFG_COUNT"}, r, n);
            axi_read(8'h08, r); check({tag, " STATUS"}, r, 32'h2);
            $display("[%0s] %0d words loaded in %0d us (AXI-Lite @25 MHz, testbench master)",
                     tag, n, ($time - t0) / 1000);
            axi_write(8'h14, 32'h0, 4'hF);                  // inputs low before release
            axi_write(8'h04, 32'h0, 4'hF);                  // CFG_MODE=0 -> live
        end
    endtask

    task exercise(input integer is_lfsr, input [127:0] tag);
        reg [31:0] r;
        integer e0;
        begin
            e0 = errors;
            mode_lfsr = is_lfsr;
            axi_write(8'h14, 32'h3, 4'hF);                  // en=1 rst=1
            axi_write(8'h14, 32'h2, 4'hF);                  // en=1 rst=0 -> running
            live_check = 1;
            repeat (200) @(posedge aclk);
            axi_write(8'h14, 32'h0, 4'hF);                  // freeze
            repeat (3) @(posedge aclk);
            axi_read(8'h18, r);
            check({tag, " AXI readback (frozen)"}, r, {16'h0, (is_lfsr ? g_lfsr : g_ctr), 2'b00});
            axi_read(8'h1C, r);
            check({tag, " IO_OE"}, r, 32'h0000_FFFC);
            $display("[%0s] frozen value %h, live cycles checked %0d, new errors %0d",
                     tag, (is_lfsr ? g_lfsr : g_ctr),
                     live_cycles, errors - e0);
            // cycle-exact stimulus via IO_PULSE: reset for 1 clk, enable for N clks.
            // Expected value computed from scratch (as the software test does).
            pulse_test(is_lfsr, 1,    tag);
            pulse_test(is_lfsr, 1000, tag);
            pulse_test(is_lfsr, 16383, tag);
            live_check = 0;
            live_cycles = 0;
        end
    endtask

    function [13:0] expect_after(input integer is_lfsr, input integer n);
        integer i;
        reg [13:0] s;
        begin
            if (!is_lfsr) expect_after = n[13:0];
            else begin
                s = 14'h0001;
                for (i = 0; i < n; i = i + 1) s = {s[12:0], s[13] ^ s[12] ^ s[11] ^ s[1]};
                expect_after = s;
            end
        end
    endfunction

    task pulse_test(input integer is_lfsr, input integer n, input [127:0] tag);
        reg [31:0] r;
        begin
            axi_write(8'h28, {16'd1, 16'h0003}, 4'hF);          // rst+en, 1 clk
            r = 32'h8; while (r[3]) axi_read(8'h08, r);
            axi_write(8'h28, {n[15:0], 16'h0002}, 4'hF);        // en, n clks
            r = 32'h8; while (r[3]) axi_read(8'h08, r);
            axi_read(8'h18, r);
            check({tag, " IO_PULSE exact"}, r, {16'h0, expect_after(is_lfsr, n), 2'b00});
            $display("[%0s] IO_PULSE n=%0d -> %h (expected %h)", tag, n, r[15:2], expect_after(is_lfsr, n));
        end
    endtask

    reg [31:0] r;
    initial begin
        for (k = 0; k < MAXW; k = k + 1) begin bs_a[k] = 32'hx; bs_b[k] = 32'hx; end
        $readmemh("counter14.hex", bs_a);
        $readmemh("lfsr14.hex", bs_b);
        for (k = 0; k < MAXW; k = k + 1) begin
            if (bs_a[k] !== 32'hx) len_a = k + 1;
            if (bs_b[k] !== 32'hx) len_b = k + 1;
        end

        repeat (5) @(posedge aclk);
        aresetn <= 1'b1;
        repeat (12) @(posedge aclk);

        axi_read(8'h00, r);  check("ID", r, 32'hEF0A_0001);
        axi_write(8'h20, 32'hDEADBEEF, 4'hF);
        axi_write(8'h20, 32'h0000_5500, 4'b0010);
        axi_read(8'h20, r);  check("SCRATCH byte strobe", r, 32'hDEAD55EF);
        axi_read(8'h08, r);  check("STATUS after reset (isolated)", r, 32'h2);

        // partial writes to CFG_DATA / IO_PULSE: SLVERR, nothing forwarded
        // (silicon lesson: Python struct.pack_into() issues byte-wise AXI writes)
        axi_write(8'h04, 32'h0000_0003, 4'hF);                      // CFG_RESET, count = 0
        repeat (12) @(posedge aclk);
        for (k = 0; k < 4; k = k + 1)
            axi_write_resp(8'h0C, 32'hFAB0_FAB1, 4'b0001 << k, 2'b10);
        axi_write_resp(8'h0C, 32'hFAB0_FAB1, 4'b0011, 2'b10);
        axi_read(8'h10, r);  check("CFG_COUNT after partials", r, 32'h0);
        check("no strobe from partials", {31'h0, dut.sw_strobe}, 32'h0);
        axi_write(8'h04, 32'h0000_0000, 4'hF);                      // live
        axi_write_resp(8'h28, {16'd100, 16'h0002}, 4'b0011, 2'b10);
        axi_read(8'h28, r);  check("IO_PULSE partial ignored", r, 32'h0);
        $display("[strobes ] partial CFG_DATA / IO_PULSE writes -> SLVERR, not forwarded");

        configure(0, len_a, "A counter14");  exercise(0, "A counter14");
        configure(1, len_b, "B lfsr14   ");  exercise(1, "B lfsr14   ");
        configure(0, len_a, "A counter14");  exercise(0, "A counter14");

        if (errors == 0) $display("RESULT: PASS (AXI path, A -> B -> A)");
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
`default_nettype wire
