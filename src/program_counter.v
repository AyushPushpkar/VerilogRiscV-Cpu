//================================================================================
// Program Counter (PC) - 8-bit CPU Component
//================================================================================
// Maintains current instruction address. Updates on posedge clk with
// next_pc value. Supports sequential execution (+1) and jumps/branches.
// Asynchronous reset to 0.
//
// ARCHITECTURE:
//   Address width: 8 bits (256 instruction capacity)
//   Synchronous: posedge clk loads next_pc
//   Asynchronous: reset (active high)
//================================================================================
// INPUTS: clk, reset, next_pc (8-bit)  | OUTPUT: pc (8-bit)
//================================================================================

`timescale 1ns/1ns

module program_counter #(
    parameter PC_WIDTH = 8
)(
    input clk,
    input reset,
    input [PC_WIDTH-1:0] next_pc, // This comes from a MUX in the top-level
    output reg [PC_WIDTH-1:0] pc
);

always @(posedge clk or posedge reset) begin
    if (reset)
        pc <= {PC_WIDTH{1'b0}};
    else
        pc <= next_pc;
end

endmodule