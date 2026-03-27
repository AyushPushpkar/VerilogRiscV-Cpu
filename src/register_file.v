//================================================================================
// Register File - 8-bit CPU Component
//================================================================================
// Provides 8 general-purpose registers (R0-R7). Dual-read (asynchronous),
// single-write (synchronous) architecture. Initialized to zero on startup.
//
// ARCHITECTURE:
//   Registers: 8 × 8-bit storage    | Address width: 3 bits
//   Read: 2 asynchronous ports      | Write: 1 synchronous port (posedge clk)
//   Total: 64 bits storage
//================================================================================
// PORTS: rs1/rs2 (read addresses) → read1/read2 (read data)
//        rd, write_data, we (write address, data, enable → write on clock)
//================================================================================

`timescale 1ns/1ns

module register_file #(
    parameter DATA_WIDTH = 8,
    parameter ADDR_WIDTH = 3  // 3 bits = 8 registers. (Change to 5 for 32 registers later!)
)(
    input clk,
    input we,                  // Write Enable
    input  [ADDR_WIDTH-1:0] rs1, // Source Register 1
    input  [ADDR_WIDTH-1:0] rs2, // Source Register 2
    input  [ADDR_WIDTH-1:0] rd,  // Destination Register
    input  [DATA_WIDTH-1:0] write_data,
    output [DATA_WIDTH-1:0] read1,
    output [DATA_WIDTH-1:0] read2
);

// Dynamically calculates total registers (2^ADDR_WIDTH)
localparam NUM_REGS = 1 << ADDR_WIDTH; 

reg [DATA_WIDTH-1:0] registers [NUM_REGS-1:0];

integer i;
initial begin
    for(i = 0; i < NUM_REGS; i = i + 1)
        registers[i] = {DATA_WIDTH{1'b0}};
end

// Asynchronous Reads
assign read1 = registers[rs1];
assign read2 = registers[rs2];

// Synchronous Write
always @(posedge clk) begin
    // RISC-V GUARD: Only write if Enable is high AND Destination is NOT Register 0
    if (we && (rd != {ADDR_WIDTH{1'b0}})) begin
        registers[rd] <= write_data;
    end
end

endmodule