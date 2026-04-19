//================================================================================
// Control Unit - 8-bit CPU Component
//================================================================================
// Decodes instruction opcode and funct fields. Generates control signals:
// reg_write (register write enable), mem_read/write (memory operations),
// alu_src (register vs immediate), jump/branch (control flow).
//
// IMMUTABLE INSTRUCTION FORMAT:
//   [31:28] Reserved | [27:24] funct | [23:21] rs2 | [20:18] rs1 
//   [17:15] rd       | [14:7]  imm   | [6:0] opcode
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
    input [6:0] opcode,
    input [2:0] funct3,
    input [6:0] funct7,
    output [6:0] funct7_out,
    output reg reg_write,
    output reg mem_read,
    output reg mem_write,
    output reg alu_src,
    output reg jump,
    output reg branch,
    output reg [2:0] alu_ctrl
);

always @(*) begin
    // Defaults
    reg_write  = 0;
    mem_read   = 0;
    mem_write  = 0;
    alu_src    = 0;
    jump       = 0;
    jalr       = 0;
    branch     = 0;
    alu_ctrl   = 3'b000;        // Default = ADD
    funct7_out = 7'b0000000;

    // case(alu_ctrl)

    //     // ==========================
    //     // R-TYPE
    //     // ==========================
    //     `OP_OP: begin
    //         reg_write  = 1;
    //         alu_ctrl   = funct3;     // pass group
    //         funct7_out = funct7;     // pass variant
    //     end

    //     // ==========================
    //     // I-TYPE
    //     // ==========================
    //     `OP_OP_IMM: begin
    //         reg_write  = 1;
    //         alu_src    = 1;
    //         alu_ctrl   = funct3;
    //         funct7_out = funct7; // needed for SRAI
    //     end

    //     // ==========================
    //     // LOAD
    //     // ==========================
    //     `OP_LOAD: begin
    //         reg_write = 1;
    //         mem_read  = 1;
    //         alu_src   = 1;
    //         alu_ctrl  = 3'b000; // ADD for address
    //     end

    //     // ==========================
    //     // STORE
    //     // ==========================
    //     `OP_STORE: begin
    //         mem_write = 1;
    //         alu_src   = 1;
    //         alu_ctrl  = 3'b000;
    //     end

    //     // ==========================
    //     // BRANCH
    //     // ==========================
    //     `OP_BRANCH: begin
    //         branch   = 1;
    //         alu_ctrl = funct3; // BEQ/BNE logic later
    //     end

    //     // ==========================
    //     // JAL
    //     // ==========================
    //     `OP_JAL: begin
    //         reg_write = 1;
    //         jump      = 1;
    //     end

    //     // ==========================
    //     // JALR
    //     // ==========================
    //     `OP_JALR: begin
    //         reg_write = 1;
    //         jalr      = 1;
    //         alu_src   = 1;
    //         alu_ctrl  = 3'b000;
    //     end

    //     // ==========================
    //     // LUI
    //     // ==========================
    //     `OP_LUI: begin
    //         reg_write = 1;
    //         alu_src   = 1;
    //     end

    //     // ==========================
    //     // AUIPC
    //     // ==========================
    //     `OP_AUIPC: begin
    //         reg_write = 1;
    //         alu_src   = 1;
    //         alu_ctrl  = 3'b000;
    //     end

    // endcase
 case(alu_ctrl)
//add/sub/mul
3'b000: begin
    if (funct7_out == `FN_SUB)
        result = A - B;
    else if (funct7_out == `FN_M_EXT)
        result = A * B;
    else
        result = A + B;
end   
//xor/xnor/div
3'b100: begin
    if (funct7_out == `FN_M_EXT)
        result = A / B;
    else if (funct7_out == `FN_SUB)
        result = ~(A ^ B); // XNOR
    else
        result = A ^ B;
end
//or/orn/rem
3'b110: begin
    if (funct7_out == `FN_M_EXT)
        result = A % B;
    else if (funct7_out == `FN_SUB)
        result = A | ~B; // ORN
    else
        result = A | B;
end
//and/andn
3'b111: begin
    if (funct7_out == `FN_SUB)
        result = A & ~B;
    else
        result = A & B;
end
//shift =rotate
3'b101: begin
    if (funct7_out == `FN_ROT)
        result = (A >> B[2:0]) | (A << (8 - B[2:0]));
    else if (funct7_out == `FN_SUB)
        result = $signed(A) >>> B[2:0];
    else
        result = A >> B[2:0];
end

endcase
end
endmodule