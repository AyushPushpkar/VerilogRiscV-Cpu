//================================================================================
// Control Unit - 8-bit CPU Component
//================================================================================
// Decodes instruction opcode and funct fields. Generates control signals:
// reg_write (register write enable), mem_read/write (memory operations),
// alu_src (register vs immediate), jump/branch (control flow).
//
// Instruction format: opcode[31:28] + funct[27:24] + fields + imm[7:0]
// Uses define constants (OP_MATH, OP_MOV, OP_LOAD, etc.) for opcodes.
//================================================================================
// OUTPUT SIGNALS:
//   reg_write: Enable register write  | mem_read: Enable memory read
//   mem_write: Enable memory write    | alu_src: Select ALU operand source
//   jump/branch: Control flow ops     | alu_ctrl[3:0]: ALU operation code
//================================================================================

`timescale 1ns/1ns
`include "defines.v"

module control_unit(
    input [3:0] opcode,
    input [3:0] funct,
    output reg reg_write,
    output reg mem_read,
    output reg mem_write,
    output reg alu_src,
    output reg jump,
    output reg branch,
    output reg [3:0] alu_ctrl
);

always @(*) begin
    // Default values to prevent latches
    reg_write = 0;
    mem_read  = 0;
    mem_write = 0;
    alu_src   = 0;
    jump      = 0;
    branch    = 0;
    alu_ctrl  = `FN_ADD; // Default to ADD logic

    case(opcode)
        // Register-to-Register Math
        `OP_MATH: begin 
            reg_write = 1; 
            alu_ctrl  = funct; // Pass the specific math (ADD, SUB, XOR, etc.)
        end

        // M-Extension (Multiplication/Division)
        `OP_M_EXT: begin
            reg_write = 1;      // Enable saving the MUL/DIV result to RD
            alu_src   = 0;      // M-Extension uses two registers (RS1, RS2)
            alu_ctrl  = funct;   // Pass FN_MUL, FN_DIV, etc. to the Execution Unit
        end

        // MOV Immediate (R[rd] = Immediate)
        `OP_MOV: begin 
            reg_write = 1; 
            alu_src   = 1; 
            alu_ctrl  = `FN_ADD; // Just adding 0+Imm in the ALU
        end

        // LOAD from Memory
        `OP_LOAD: begin 
            reg_write = 1; 
            mem_read  = 1; 
            alu_src   = 1; 
            alu_ctrl  = `FN_ADD; // Calculate address: Reg + Imm
        end

        // STORE to Memory
        `OP_STORE: begin 
            mem_write = 1; 
            alu_src   = 1; 
            alu_ctrl  = `FN_ADD; // Calculate address: Reg + Imm
        end

        // Unconditional Jump
        `OP_JMP: begin 
            jump = 1; 
        end

        // Branch if Equal
        `OP_BEQ: begin 
            branch   = 1; 
            alu_ctrl = `FN_SUB; // Subtract to check if Zero flag triggers
        end

        default: begin
            // Safety fallback
            reg_write = 0;
        end
    endcase
end

endmodule