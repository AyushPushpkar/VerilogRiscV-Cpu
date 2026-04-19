//================================================================================
// RISC-V Defines - RV32I + RV32M + Internal CPU Control Encodings
//================================================================================
// Centralized constants for:
//   - RV32I major opcodes
//   - RV32I funct3 / funct7 fields
//   - RV32M funct3 / funct7 fields
//   - Internal datapath select encodings used by the CPU
//
// NOTES:
//   - ISA encodings follow standard RV32I / RV32M
//   - Internal control encodings are local to this project
//   - Keeping these in one file makes decode and datapath logic cleaner
//================================================================================

`ifndef DEFINES_V
`define DEFINES_V

//================================================================================
// RV32I MAJOR OPCODES
//================================================================================
`define OP_LOAD      7'b0000011
`define OP_STORE     7'b0100011
`define OP_OP_IMM    7'b0010011
`define OP_AUIPC     7'b0010111
`define OP_OP        7'b0110011
`define OP_LUI       7'b0110111
`define OP_BRANCH    7'b1100011
`define OP_JALR      7'b1100111
`define OP_JAL       7'b1101111

//================================================================================
// COMMON FUNCT7 VALUES
//================================================================================
`define F7_BASE      7'b0000000
`define F7_SUB_SRA   7'b0100000
`define F7_M_EXT     7'b0000001

//================================================================================
// ALU / OP-IMM / OP FUNCT3 VALUES
//================================================================================
`define FN_ADD_SUB   3'b000
`define FN_SLL       3'b001
`define FN_SLT       3'b010
`define FN_SLTU      3'b011
`define FN_XOR       3'b100
`define FN_SRL_SRA   3'b101
`define FN_OR        3'b110
`define FN_AND       3'b111

//================================================================================
// BRANCH FUNCT3 VALUES
//================================================================================
`define BR_BEQ       3'b000
`define BR_BNE       3'b001
`define BR_BLT       3'b100
`define BR_BGE       3'b101
`define BR_BLTU      3'b110
`define BR_BGEU      3'b111

//================================================================================
// LOAD FUNCT3 VALUES
//================================================================================
`define LD_LB        3'b000
`define LD_LH        3'b001
`define LD_LW        3'b010
`define LD_LBU       3'b100
`define LD_LHU       3'b101

//================================================================================
// STORE FUNCT3 VALUES
//================================================================================
`define ST_SB        3'b000
`define ST_SH        3'b001
`define ST_SW        3'b010

//================================================================================
// JALR FUNCT3 VALUE
//================================================================================
`define JALR_F3      3'b000

//================================================================================
// RV32M FUNCT3 VALUES (used with OP_OP + F7_M_EXT)
//================================================================================
`define FN_MUL       3'b000
`define FN_MULH      3'b001
`define FN_MULHSU    3'b010
`define FN_MULHU     3'b011
`define FN_DIV       3'b100
`define FN_DIVU      3'b101
`define FN_REM       3'b110
`define FN_REMU      3'b111

//================================================================================
// INTERNAL ALU OPERAND-A SELECT
//================================================================================
// Used by cpu_top / control_unit to select ALU input A.
//
//   ASEL_RS1  : Normal register-based operations
//   ASEL_PC   : AUIPC and PC-relative computations
//   ASEL_ZERO : LUI and similar immediate-only constructions
//================================================================================
`define ASEL_RS1     2'b00
`define ASEL_PC      2'b01
`define ASEL_ZERO    2'b10

//================================================================================
// INTERNAL WRITE-BACK SELECT
//================================================================================
// Used by cpu_top / control_unit to select register write-back data.
//
//   WB_ALU    : ALU result
//   WB_MEM    : Load data from memory
//   WB_PC4    : PC + 4 (JAL / JALR)
//================================================================================
`define WB_ALU       2'b00
`define WB_MEM       2'b01
`define WB_PC4       2'b10

`endif

// B-EXTENSION (BIT MANIPULATION)

// Logical with Negation
`define F7_ANDN      7'b0100000   // ANDN = A & ~B
`define F7_ORN       7'b0100000   // ORN  = A | ~B
`define F7_XNOR      7'b0100000   // XNOR = ~(A ^ B)

// Rotate Instructions
`define F7_ROT       7'b0110000   // ROL / ROR
