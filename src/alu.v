//================================================================================
// ALU (Arithmetic Logic Unit) - 8-bit CPU Component
//================================================================================
// Performs arithmetic and logical operations on two 8-bit operands.
// Generates zero flag for conditional execution. Combinational logic.
//
// OPERATIONS (4-bit opcode):
//   0000: ADD   | 0001: SUB   | 0010: AND   | 0011: OR
//   0100: XOR   | 0101: MOV   | 0110: SLL   | 0111: SRL
//   1000: SRA   | 1001: SLT   | 1010: SLTU  | Default: 0
//================================================================================
// INPUTS:  A (8-bit), B (8-bit), opcode (4-bit)
// OUTPUTS: result (8-bit), zero flag
//================================================================================

`timescale 1ns/1ns
`include "defines.v"

module alu #(
    parameter DATA_WIDTH = 8,
    parameter OP_WIDTH = 4
)(
    input  [DATA_WIDTH-1:0] A,
    input  [DATA_WIDTH-1:0] B,
    input  is_mul_div, // Enable signal from Level 1
    input  [OP_WIDTH-1:0]   opcode,
    output reg [DATA_WIDTH-1:0] result,
    output zero
);

// Dynamically calculates the number of bits needed for the shift amount.
// For an 8-bit CPU, we only shift by 0-7 (needs 3 bits). 
// When you change DATA_WIDTH to 16, this automatically becomes 4!
localparam SHIFT_WIDTH = $clog2(DATA_WIDTH);

always @(*) begin

    if (is_mul_div) begin
        
        // M-EXTENSION LANE (Multiplication & Division) 
        case(opcode)
            `FN_MUL: result = A * B; 
            `FN_DIV: result = (B != {DATA_WIDTH{1'b0}}) ? (A / B) : {DATA_WIDTH{1'b1}}; 
            `FN_REM: result = (B != {DATA_WIDTH{1'b0}}) ? (A % B) : A; 
            default: result = {DATA_WIDTH{1'b0}};
        endcase
    end else begin
        
        // BASE INTEGER LANE (RV32I) 
        case(opcode)
            `FN_ADD:  result = A + B; 
            `FN_SUB:  result = A - B; 
            `FN_AND:  result = A & B; 
            `FN_OR:   result = A | B; 
            `FN_XOR:  result = A ^ B; 
            `FN_MOV:  result = B;
            `FN_SLL:  result = A << B[SHIFT_WIDTH-1:0]; 
            `FN_SRL:  result = A >> B[SHIFT_WIDTH-1:0]; 
            `FN_SRA:  result = $signed(A) >>> B[SHIFT_WIDTH-1:0]; 
            `FN_SLT:  result = ($signed(A) < $signed(B)) ? {{DATA_WIDTH-1{1'b0}}, 1'b1} : {DATA_WIDTH{1'b0}};
            `FN_SLTU: result = (A < B) ? {{DATA_WIDTH-1{1'b0}}, 1'b1} : {DATA_WIDTH{1'b0}};
            default:  result = {DATA_WIDTH{1'b0}};
        endcase
    end

end

assign zero = (result == {DATA_WIDTH{1'b0}});

endmodule