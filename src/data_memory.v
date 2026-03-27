//================================================================================
// Data Memory (RAM) - 8-bit CPU Component
//================================================================================
// Random access memory for program data storage. Read/write operations
// controlled by mem_read/mem_write signals. Initialized to zero.
//
// ARCHITECTURE:
//   Capacity: 256 bytes (8-bit address space)
//   Width: 8 bits per location
//   Total: 2048 bits
//   Access: Synchronous (updated on posedge clk)
//================================================================================
// CONTROLS: mem_read, mem_write (can be simultaneous)
// DATA: address (8-bit), write_data (8-bit) → read_data (8-bit)
//================================================================================

`timescale 1ns/1ns

module data_memory #(
    parameter ADDR_WIDTH = 8,
    parameter DATA_WIDTH = 8
)(
    input clk,
    input mem_read,       // From Control Unit
    input mem_write,      // From Control Unit
    input [ADDR_WIDTH-1:0] address,    // From ALU Result
    input [DATA_WIDTH-1:0] write_data, // From Register File (Read Data 2)
    output [DATA_WIDTH-1:0] read_data  // To Register File (Write Data Mux)
);

    // 256 locations of 8-bit data
    reg [DATA_WIDTH-1:0] ram [0:(1<<ADDR_WIDTH)-1];

    // 1. Memory Initialization (Clear RAM to 0)
    integer i;
    initial begin
        for (i = 0; i < (1<<ADDR_WIDTH); i = i + 1) begin
            ram[i] = {DATA_WIDTH{1'b0}};
        end
    end

    // 2. Synchronous Write (Only happens on Clock Edge)
    // This follows standard hardware behavior for RAM
    always @(posedge clk) begin
        if (mem_write) begin
            ram[address] <= write_data;
        end
    end

    // 3. Asynchronous Read (Immediate Response)
    // This is the "Best" way for your Single-Cycle design.
    // If mem_read is high, it puts data on the wire immediately.
    // If not, it outputs 0 to prevent "floating" wires.
    assign read_data = (mem_read) ? ram[address] : {DATA_WIDTH{1'b0}};

endmodule