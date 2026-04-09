// Opcode Definitions (7-bit RISC-V Standard Placement)
`define OP_LOAD  7'b0000011 // Standard RV32I LOAD
`define OP_MATH  7'b0110011 // Standard RV32I OP
`define OP_MOV   7'b0010011 // Standard RV32I OP-IMM (Used for ADDI/MOV)
`define OP_STORE 7'b0100011 // Standard RV32I STORE
`define OP_BEQ   7'b1100011 // Standard RV32I BRANCH
`define OP_JMP   7'b1101111 // Standard RV32I JAL

// M-Extension (Mapped to RISC-V "custom-0" space to preserve Level 1 fast-decode)
`define OP_M_EXT 7'b0001011

// Function Code Definitions (For the 'funct' field)
`define FN_ADD   4'b0000
`define FN_SUB   4'b0001
`define FN_AND   4'b0010
`define FN_OR    4'b0011
`define FN_XOR   4'b0100
`define FN_MOV   4'b0101
`define FN_SLL   4'b0110
`define FN_SRL   4'b0111
`define FN_SRA   4'b1000
`define FN_SLT   4'b1001
`define FN_SLTU  4'b1010

// Function Codes for OP_M_EXT (M-Extension)
`define FN_MUL      4'b0000  // Multiply
`define FN_DIV      4'b0001  // Division 
`define FN_REM      4'b0010  // Remainder 