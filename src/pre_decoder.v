//================================================================================
// Pre-Decoder - Level 1 Hierarchical Decoder
//================================================================================
// Sits in the Fetch stage. Analyzes the instruction immediately to triage 
// the working module (Base ALU vs. M-Extension vs. future AI extensions).
// This generates the 'is_mul_div' signal used to switch ALU lanes, 
// shortening the critical path.
//================================================================================

`timescale 1ns/1ns
`include "defines.v"

module pre_decoder #(
    parameter INSTR_WIDTH = 32,
    parameter OP_WIDTH = 4
)(
    input  [INSTR_WIDTH-1:0] instruction,
    output reg               is_mul_div, // High for OP_M_EXT
    output reg               is_base     // High for Base Integer operations
);

    // Extract opcode from the top bits (e.g., bits [31:28])
    wire [OP_WIDTH-1:0] opcode = instruction[INSTR_WIDTH-1 : INSTR_WIDTH-OP_WIDTH];

    always @(*) begin
        // Default values to prevent latches
        is_mul_div = 1'b0;
        is_base    = 1'b0;

        case (opcode)
            `OP_M_EXT: begin
                is_mul_div = 1'b1;
            end
            
            `OP_MATH, `OP_MOV, `OP_LOAD, `OP_STORE: begin
                is_base = 1'b1;
            end
            
            default: begin
                // JMP, BEQ, or invalid opcodes don't need the ALU math lanes
                is_mul_div = 1'b0;
                is_base    = 1'b0;
            end
        endcase
    end

endmodule