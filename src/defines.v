// Opcode Definitions
`define OP_MATH  4'b0000
`define OP_MOV   4'b0101
`define OP_LOAD  4'b0110
`define OP_STORE 4'b0111
`define OP_JMP   4'b1000
`define OP_BEQ   4'b1001

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