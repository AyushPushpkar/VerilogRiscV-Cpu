//================================================================================
// Program Counter (PC) - RV64I Architectural PC
//================================================================================
// Holds the current instruction address for the CPU.
//
// FEATURES:
//   - 64-bit architectural PC (Parameterized)
//   - Synchronous update on posedge clk
//   - Asynchronous reset to configurable BOOT_ADDR
//   - Enable signal for pipeline stalls
//================================================================================

`timescale 1ns/1ns

module program_counter #(
    parameter PC_WIDTH = 64,
    parameter BOOT_ADDR = 64'h0000_0000_0000_0000 
)(
    input                         clk,
    input                         reset,
    input                         enable,   // High to update PC, Low to stall
    input      [PC_WIDTH-1:0]     next_pc,
    output reg [PC_WIDTH-1:0]     pc
);

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            pc <= BOOT_ADDR; 
        end
        else if (enable) begin
            pc <= next_pc;
        end
        // If enable is low, the PC simply holds its current value (stalls).
    end

endmodule