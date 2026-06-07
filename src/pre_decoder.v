//================================================================================
// Pre-Decoder - Lightweight Instruction Classification
//================================================================================
// Performs early instruction classification for optional microarchitectural use.
//
// PURPOSE:
//   - Not part of architectural RISC-V execution semantics
//   - Intended for early instruction grouping, monitoring, or future pipeline use
//
// CLASSIFICATION OUTPUTS:
//   is_mul_div       : RV32M OP-class instruction
//   is_memory        : Any load/store instruction
//   is_load          : RV32I load instruction
//   is_store         : RV32I store instruction
//   is_control_flow  : Any branch/jump instruction
//   is_branch        : Conditional branch
//   is_jump          : JAL or JALR
//   illegal_predecode: Obvious unsupported/illegal opcode/form at predecode level
//
// DESIGN NOTES:
//   - This is a lightweight classifier, not a full control decoder
//   - It uses opcode/funct3/funct7 only for broad categorization
//   - It is intentionally conservative and simple
//================================================================================

`timescale 1ns/1ns
`include "defines.v"

module pre_decoder #(
    parameter ILEN = 32,
    parameter OP_WIDTH    = 7
)(
    input  [ILEN-1:0] instruction,

    output reg is_mul_div,
    output reg is_memory,
    output reg is_load,
    output reg is_store,
    output reg is_control_flow,
    output reg is_branch,
    output reg is_jump,
    output reg illegal_predecode
);

    //========================================================================
    // FIELD EXTRACTION
    //========================================================================
    wire [OP_WIDTH-1:0] opcode = instruction[6:0];
    wire [2:0]          funct3 = instruction[14:12];
    wire [6:0]          funct7 = instruction[31:25];

    always @(*) begin
        //====================================================================
        // DEFAULTS
        //====================================================================
        is_mul_div       = 1'b0;
        is_memory        = 1'b0;
        is_load          = 1'b0;
        is_store         = 1'b0;
        is_control_flow  = 1'b0;
        is_branch        = 1'b0;
        is_jump          = 1'b0;
        illegal_predecode = 1'b0;

        //====================================================================
        // OPCODE-BASED LIGHTWEIGHT CLASSIFICATION
        //====================================================================
        case (opcode)

            //================================================================
            // LOADS
            //================================================================
            `OP_LOAD: begin
                is_memory = 1'b1;
                is_load   = 1'b1;

                case (funct3)
                    `LD_LB,
                    `LD_LH,
                    `LD_LW,
                    `LD_LBU,
                    `LD_LHU: begin
                        // valid load subtype
                    end

                    default: begin
                        illegal_predecode = 1'b1;
                    end
                endcase
            end

            //================================================================
            // STORES
            //================================================================
            `OP_STORE: begin
                is_memory = 1'b1;
                is_store  = 1'b1;

                case (funct3)
                    `ST_SB,
                    `ST_SH,
                    `ST_SW: begin
                        // valid store subtype
                    end

                    default: begin
                        illegal_predecode = 1'b1;
                    end
                endcase
            end

            //================================================================
            // CONDITIONAL BRANCHES
            //================================================================
            `OP_BRANCH: begin
                is_control_flow = 1'b1;
                is_branch       = 1'b1;

                case (funct3)
                    `BR_BEQ,
                    `BR_BNE,
                    `BR_BLT,
                    `BR_BGE,
                    `BR_BLTU,
                    `BR_BGEU: begin
                        // valid branch subtype
                    end

                    default: begin
                        illegal_predecode = 1'b1;
                    end
                endcase
            end

            //================================================================
            // JUMPS
            //================================================================
            `OP_JAL: begin
                is_control_flow = 1'b1;
                is_jump         = 1'b1;
            end

            `OP_JALR: begin
                is_control_flow = 1'b1;
                is_jump         = 1'b1;

                if (funct3 != `JALR_F3)
                    illegal_predecode = 1'b1;
            end

            //================================================================
            // OP-CLASS INSTRUCTIONS
            //   Detect RV32M through funct7
            //================================================================
            `OP_OP: begin
                if (funct7 == `F7_M_EXT) begin
                    case (funct3)
                        `FN_MUL,
                        `FN_MULH,
                        `FN_MULHSU,
                        `FN_MULHU,
                        `FN_DIV,
                        `FN_DIVU,
                        `FN_REM,
                        `FN_REMU: begin
                            is_mul_div = 1'b1;
                        end

                        default: begin
                            illegal_predecode = 1'b1;
                        end
                    endcase
                end
                else if ((funct7 == `F7_BASE) || (funct7 == `F7_SUB_SRA)) begin
                    // legal RV32I OP-class encoding family at predecode level
                end
                else begin
                    illegal_predecode = 1'b1;
                end
            end

            //================================================================
            // OTHER SUPPORTED ARCHITECTURAL CLASSES
            //================================================================
            `OP_OP_IMM,
            `OP_LUI,
            `OP_AUIPC: begin
                // supported classes, nothing special to classify here
            end

            //================================================================
            // UNSUPPORTED / ILLEGAL OPCODE
            //================================================================
            default: begin
                illegal_predecode = 1'b1;
            end

        endcase
    end

endmodule