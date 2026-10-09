`default_nettype none
// -----------------------------------------------------------------------------
// FPGA/simulation model of the OpenRAM macro sram_1rw1r_32_256_8_sky130 used by
// FABulous' BlockRAM_1KB. Same module name and ports, so it replaces the
// (* blackbox *) stub when building the fabric for the Versal.
//   port 0: write (csb0 & web0 active low, byte mask wmask0), din0 sampled on clk0
//   port 1: read  (csb1 active low), address registered, dout1 valid after clk1
// The real macro registers its inputs and drives the output after a delay,
// i.e. a synchronous 1-cycle read - which is exactly a Versal BRAM/LUTRAM read.
// Read-during-write to the same address returns OLD data (as OpenRAM 1rw1r).
// For the ASIC flow this file is NOT used - the hard macro is.
// -----------------------------------------------------------------------------
module sram_1rw1r_32_256_8_sky130 #(
    parameter integer NUM_WMASKS = 4,
    parameter integer DATA_WIDTH = 32,
    parameter integer ADDR_WIDTH = 8,
    parameter integer RAM_DEPTH  = 1 << ADDR_WIDTH,
    parameter integer DELAY      = 3
) (
    input  wire                  clk0,
    input  wire                  csb0,
    input  wire                  web0,
    input  wire [NUM_WMASKS-1:0] wmask0,
    input  wire [ADDR_WIDTH-1:0] addr0,
    input  wire [DATA_WIDTH-1:0] din0,
    output wire [DATA_WIDTH-1:0] dout0,
    input  wire                  clk1,
    input  wire                  csb1,
    input  wire [ADDR_WIDTH-1:0] addr1,
    output reg  [DATA_WIDTH-1:0] dout1
);
    (* ram_style = "block" *)
    reg [DATA_WIDTH-1:0] mem [0:RAM_DEPTH-1];

    integer i;
    initial begin
        for (i = 0; i < RAM_DEPTH; i = i + 1) mem[i] = {DATA_WIDTH{1'b0}};
        dout1 = {DATA_WIDTH{1'b0}};
    end

    // Vivado byte-write-enable BRAM template (one always block, loop over bytes)
    integer b;
    always @(posedge clk0)
        if (!csb0 && !web0)
            for (b = 0; b < NUM_WMASKS; b = b + 1)
                if (wmask0[b]) mem[addr0][8 * b +: 8] <= din0[8 * b +: 8];

    always @(posedge clk1)
        if (!csb1) dout1 <= mem[addr1];

    assign dout0 = {DATA_WIDTH{1'b0}};   // port 0 read data unused by BlockRAM_1KB
endmodule
`default_nettype wire
