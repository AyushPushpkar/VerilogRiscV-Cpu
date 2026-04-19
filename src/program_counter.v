//================================================================================
// Program Counter (PC) - RV32I Style 32-Bit Architectural PC
//================================================================================
// Holds the current instruction address for the CPU.
//
// FEATURES:
//   - 32-bit architectural PC
//   - Synchronous update on posedge clk
//   - Asynchronous reset to 0
//   - Simple single-cycle friendly design
//
// DESIGN NOTES:
//   - The PC is kept as a full 32-bit value even if instruction/data memories
//     are smaller in size.
//   - Lower address bits may still be checked elsewhere for alignment.
//   - Memory modules are free to use only the low address bits they need.
//================================================================================

`timescale 1ns/1ns

module program_counter #(
    parameter PC_WIDTH = 32
)(
    input                    clk,
    input                    reset,
    input      [PC_WIDTH-1:0] next_pc,
    output reg [PC_WIDTH-1:0] pc
);

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            pc <= {PC_WIDTH{1'b0}};
        end
        else begin
            pc <= next_pc;
        end
    end

endmodule