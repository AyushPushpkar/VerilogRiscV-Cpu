//==============================================================================
// RISC-V ISA and CPU Control Definitions
//==============================================================================
//
// Description:
//   Centralized instruction encodings and internal control definitions for the
//   RV64 CPU implementation.
//
// ISA Support:
//   - RV64I Base Integer Instruction Set
//   - RV64M Integer Multiplication and Division Extension
//   - Selected RV64B Bit-Manipulation Instructions
//
// Internal Definitions:
//   - ALU operand source selection
//   - Register write-back source selection
//
// Notes:
//   - ISA encodings follow the RISC-V specification.
//   - Internal control encodings are local to this implementation.
//   - Keeping all encodings in a single file simplifies decode and control
//     logic maintenance.
//
//==============================================================================

`ifndef DEFINES_V
`define DEFINES_V


//==============================================================================
// RV64I Major Opcodes
//==============================================================================

`define OP_LOAD       7'b0000011
`define OP_STORE      7'b0100011
`define OP_OP_IMM     7'b0010011
`define OP_AUIPC      7'b0010111

// RV64 word-immediate instructions:
// ADDIW, SLLIW, SRLIW, SRAIW
`define OP_OP_IMM_32  7'b0011011

`define OP_OP         7'b0110011
`define OP_LUI        7'b0110111

// RV64 word register-register instructions:
// ADDW, SUBW, SLLW, SRLW, SRAW
`define OP_OP_32      7'b0111011

`define OP_BRANCH     7'b1100011
`define OP_JALR       7'b1100111
`define OP_JAL        7'b1101111


//==============================================================================
// Common Funct7 Encodings
//==============================================================================

`define F7_BASE       7'b0000000
`define F7_SUB_SRA    7'b0100000
`define F7_M_EXT      7'b0000001


//==============================================================================
// ALU / OP-IMM / OP Funct3 Encodings
//==============================================================================

`define FN_ADD_SUB    3'b000
`define FN_SLL        3'b001
`define FN_SLT        3'b010
`define FN_SLTU       3'b011
`define FN_XOR        3'b100
`define FN_SRL_SRA    3'b101
`define FN_OR         3'b110
`define FN_AND        3'b111


//==============================================================================
// Branch Instruction Funct3 Encodings
//==============================================================================

`define BR_BEQ        3'b000
`define BR_BNE        3'b001
`define BR_BLT        3'b100
`define BR_BGE        3'b101
`define BR_BLTU       3'b110
`define BR_BGEU       3'b111


//==============================================================================
// Load Instruction Funct3 Encodings
//==============================================================================
//
// LB   : Load Byte
// LH   : Load Halfword
// LW   : Load Word
// LD   : Load Doubleword
// LBU  : Load Byte Unsigned
// LHU  : Load Halfword Unsigned
// LWU  : Load Word Unsigned
//

`define LD_LB         3'b000
`define LD_LH         3'b001
`define LD_LW         3'b010
`define LD_LD         3'b011
`define LD_LBU        3'b100
`define LD_LHU        3'b101
`define LD_LWU        3'b110


//==============================================================================
// Store Instruction Funct3 Encodings
//==============================================================================

`define ST_SB         3'b000
`define ST_SH         3'b001
`define ST_SW         3'b010
`define ST_SD         3'b011


//==============================================================================
// JALR Funct3 Encoding
//==============================================================================

`define JALR_F3       3'b000


//==============================================================================
// RV64M Extension Funct3 Encodings
//==============================================================================

`define FN_MUL        3'b000
`define FN_MULH       3'b001
`define FN_MULHSU     3'b010
`define FN_MULHU      3'b011
`define FN_DIV        3'b100
`define FN_DIVU       3'b101
`define FN_REM        3'b110
`define FN_REMU       3'b111

//==============================================================================
// RV64M WORD OPERATIONS (OP_OP_32 + F7_M_EXT)
//==============================================================================
//
// These reuse the same funct3 encodings as the RV64M operations above.
// Separate aliases improve readability in decode and ALU logic.
//

`define FN_MULW       3'b000
`define FN_DIVW       3'b100
`define FN_DIVUW      3'b101
`define FN_REMW       3'b110
`define FN_REMUW      3'b111


//==============================================================================
// ALU Operand A Source Selection
//==============================================================================
//
// ASEL_RS1  : Register source operand
// ASEL_PC   : Program counter
// ASEL_ZERO : Constant zero
//

`define ASEL_RS1      2'b00
`define ASEL_PC       2'b01
`define ASEL_ZERO     2'b10


//==============================================================================
// Register Write-Back Source Selection
//==============================================================================
//
// WB_ALU : ALU result
// WB_MEM : Memory load result
// WB_PC4 : PC + 4
//

`define WB_ALU        2'b00
`define WB_MEM        2'b01
`define WB_PC4        2'b10


//==============================================================================
// Selected RV64B Bit-Manipulation Encodings
//==============================================================================

// ANDN / ORN / XNOR
`define F7_ANDN       7'b0100000
`define F7_ORN        7'b0100000
`define F7_XNOR       7'b0100000

// ROL / ROR
`define F7_ROT        7'b0110000


`endif