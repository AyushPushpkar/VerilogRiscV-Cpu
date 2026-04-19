// RISC-V OPCODES (7-bit)
`define OP_OP        7'b0110011   // R-type
`define OP_OP_IMM    7'b0010011   // I-type ALU
`define OP_LOAD      7'b0000011   // LOAD
`define OP_STORE     7'b0100011   // STORE
`define OP_BRANCH    7'b1100011   // BRANCH
`define OP_JAL       7'b1101111   // JAL
`define OP_JALR      7'b1100111   // JALR
`define OP_LUI       7'b0110111   // LUI
`define OP_AUIPC     7'b0010111   // AUIPC

// FUNCT3 (ALU OPERATION GROUP)
`define F3_ADD_SUB   3'b000
`define F3_SLL       3'b001
`define F3_SLT       3'b010
`define F3_SLTU      3'b011
`define F3_XOR       3'b100
`define F3_SRL_SRA   3'b101
`define F3_OR        3'b110
`define F3_AND       3'b111


// ==========================================
// M-EXTENSION (funct7 = 0000001)
// ==========================================
`define F3_MUL      3'b000
`define F3_MULH     3'b001
`define F3_MULHSU   3'b010
`define F3_MULHU    3'b011
`define F3_DIV      3'b100
`define F3_DIVU     3'b101
`define F3_REM      3'b110
`define F3_REMU     3'b111


// FUNCT7 (ALU OPERATION VARIANT)
`define F7_ADD       7'b0000000
`define F7_SUB       7'b0100000
`define F7_M_EXT     7'b0000001   // MUL, DIV, REM
`define F7_SRL       7'b0000000
`define F7_SRA       7'b0100000

// B-EXTENSION (BIT MANIPULATION)

// Logical with Negation
`define F7_ANDN      7'b0100000   // ANDN = A & ~B
`define F7_ORN       7'b0100000   // ORN  = A | ~B
`define F7_XNOR      7'b0100000   // XNOR = ~(A ^ B)

// Rotate Instructions
`define F7_ROT       7'b0110000   // ROL / ROR
