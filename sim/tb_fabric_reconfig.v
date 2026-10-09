`timescale 1ns / 1ps
`default_nettype none
// -----------------------------------------------------------------------------
// tb_fabric_reconfig : runtime reconfiguration of the raw eFPGA (no wrapper)
//   1) load counter14 -> compare against golden model
//   2) load lfsr14    -> compare (no global reset in between)
//   3) load counter14 again -> compare (A -> B -> A)
// Pin map of both demo designs: pin0 = sync reset, pin1 = enable, pins 15..2 = data
// -----------------------------------------------------------------------------
module tb_fabric_reconfig;
    localparam integer MAXW = 4096;
    localparam integer NCHK = 300;

    reg         CLK = 1'b0;
    reg         resetn = 1'b1;
    reg         strobe = 1'b0;
    reg  [31:0] wdata = 32'h0;
    reg  [15:0] O_top = 16'h0;
    wire [15:0] I_top, T_top;
    wire [31:0] A_cfg, B_cfg, C_acc;
    wire        com_active, rx_led;

    always #20 CLK = ~CLK;   // 25 MHz, same as the planned Versal PL clock

    eFPGA_top dut (
        .A_config_C(A_cfg), .B_config_C(B_cfg), .Config_accessC(C_acc),
        .I_top(I_top), .O_top(O_top), .T_top(T_top),
        .CLK(CLK), .resetn(resetn),
        .SelfWriteStrobe(strobe), .SelfWriteData(wdata),
        .Rx(1'b1), .ComActive(com_active), .ReceiveLED(rx_led),
        .s_clk(1'b0), .s_data(1'b0)
    );

    reg [31:0] bs_a [0:MAXW-1];
    reg [31:0] bs_b [0:MAXW-1];
    integer    len_a, len_b, errors = 0, k;

    // golden models, fed by the same pins as the fabric
    reg [13:0] g_ctr, g_lfsr;
    always @(posedge CLK) begin
        if (O_top[1]) begin
            g_ctr  <= O_top[0] ? 14'd0 : g_ctr + 1'b1;
            g_lfsr <= O_top[0] ? 14'h0001
                               : {g_lfsr[12:0], g_lfsr[13] ^ g_lfsr[12] ^ g_lfsr[11] ^ g_lfsr[1]};
        end
    end

    function integer count_words(input integer which);
        integer i;
        begin
            count_words = 0;
            for (i = 0; i < MAXW; i = i + 1)
                if ((which == 0 ? bs_a[i] : bs_b[i]) !== 32'hxxxxxxxx) count_words = i + 1;
        end
    endfunction

    // SelfWrite protocol: data stable >=2 clk, 1-clk strobe, >=2 clk gap.
    // (ConfigFSM needs >= 3 clk between writes: long_frame_strobe is 2 clk wide.)
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

    task run_and_check(input integer is_lfsr, input [127:0] tag);
        integer i, e0;
        reg [13:0] exp;
        begin
            e0 = errors;
            O_top = 16'h0003;                 // en=1, rst=1
            repeat (4) @(posedge CLK);
            O_top = 16'h0002;                 // en=1, rst=0
            for (i = 0; i < NCHK; i = i + 1) begin
                @(negedge CLK);
                if (i == NCHK / 2) O_top = 16'h0000;   // pause: enable low
                if (i == NCHK / 2 + 20) O_top = 16'h0002;
                exp = is_lfsr ? g_lfsr : g_ctr;
                if (I_top[15:2] !== exp) begin
                    if (errors < 10)
                        $display("  [%0s] cyc %0d: fabric=%h gold=%h", tag, i, I_top[15:2], exp);
                    errors = errors + 1;
                end
            end
            // output-enable view of the IO tiles (1 = fabric drives the pin)
            $display("[%0s] %0d cycles checked, mismatches=%0d, last value=%h, T_top=%h",
                     tag, NCHK, errors - e0, I_top[15:2], T_top);
        end
    endtask

    initial begin
        for (k = 0; k < MAXW; k = k + 1) begin bs_a[k] = 32'hx; bs_b[k] = 32'hx; end
        $readmemh("counter14.hex", bs_a);
        $readmemh("lfsr14.hex", bs_b);
        len_a = count_words(0);
        len_b = count_words(1);
        $display("bitstreams: counter14=%0d words, lfsr14=%0d words", len_a, len_b);

        #100 resetn = 1'b0;
        #400 resetn = 1'b1;
        repeat (10) @(posedge CLK);

        load(0, len_a);  run_and_check(0, "A counter14");
        load(1, len_b);  run_and_check(1, "B lfsr14   ");
        load(0, len_a);  run_and_check(0, "A counter14");

        if (errors == 0) $display("RESULT: PASS (A -> B -> A runtime reconfiguration)");
        else             $display("RESULT: FAIL (%0d mismatches)", errors);
        $finish;
    end
endmodule
`default_nettype wire
