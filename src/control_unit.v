//================================================================================
// Control Unit - RV32I + RV32M Aware (Single-Cycle CPU)
//================================================================================
// Decodes RV32I/RV32M instruction fields and generates datapath control signals.
//
// SUPPORTED CLASSES:
//   - R-type ALU ops
//   - I-type ALU ops
//   - Loads   : LB, LH, LW, LBU, LHU
//   - Stores  : SB, SH, SW
//   - Branch  : BEQ, BNE, BLT, BGE, BLTU, BGEU
//   - Jumps   : JAL, JALR
//   - U-type  : LUI, AUIPC
//   - M-ext   : MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU
//
// DESIGN NOTES:
//   - Keeps opcode-based control simple and readable
//   - Uses explicit datapath selects for:
//       * ALU operand-A source
//       * register write-back source
//   - Marks unsupported / illegal instruction forms using illegal_instr
//   - Leaves final ALU execution details to funct3/funct7-aware ALU logic
//================================================================================

`timescale 1ns/1ns
`include "defines.v"

module control_unit(
    input  [6:0] opcode,
    input  [2:0] funct3,
    input  [6:0] funct7,

    output reg        reg_write,
    output reg        mem_read,
    output reg        mem_write,
    output reg        alu_src,
    output reg        jump,
    output reg        jalr,
    output reg        branch,
    output reg [1:0]  alu_a_sel,
    output reg [1:0]  wb_sel,
    output reg [2:0]  alu_ctrl,
    output reg [6:0]  funct7_out,
    output reg        illegal_instr
);

    always @(*) begin
        //========================================================================
        // DEFAULTS
        //========================================================================
        reg_write     = 1'b0;
        mem_read      = 1'b0;
        mem_write     = 1'b0;
        alu_src       = 1'b0;
        jump          = 1'b0;
        jalr          = 1'b0;
        branch        = 1'b0;
        alu_a_sel     = `ASEL_RS1;
        wb_sel        = `WB_ALU;
        alu_ctrl      = `FN_ADD_SUB;
        funct7_out    = `F7_BASE;
        illegal_instr = 1'b0;

        //========================================================================
        // OPCODE DECODE
        //========================================================================
        case (opcode)

            //====================================================================
            // R-TYPE REGISTER-REGISTER OPERATIONS
            //   RV32I: ADD, SUB, SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND
            //   RV32M: MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU
            //====================================================================
            `OP_OP: begin
                alu_a_sel = `ASEL_RS1;
                alu_src   = 1'b0;
                wb_sel    = `WB_ALU;

                case (funct3)
                    `FN_ADD_SUB: begin
                        if ((funct7 == `F7_BASE) || (funct7 == `F7_SUB_SRA)) begin
                            reg_write  = 1'b1;
                            alu_ctrl   = funct3;
                            funct7_out = funct7;
                        end
                        else if (funct7 == `F7_M_EXT) begin
                            reg_write  = 1'b1;
                            alu_ctrl   = funct3;
                            funct7_out = funct7;
                        end
                        else begin
                            illegal_instr = 1'b1;
                        end
                    end

                    `FN_SLL,
                    `FN_SLT,
                    `FN_SLTU,
                    `FN_XOR,
                    `FN_OR,
                    `FN_AND: begin
                        if ((funct7 == `F7_BASE) || (funct7 == `F7_M_EXT)) begin
                            reg_write  = 1'b1;
                            alu_ctrl   = funct3;
                            funct7_out = funct7;
                        end
                        else begin
                            illegal_instr = 1'b1;
                        end
                    end

                    `FN_SRL_SRA: begin
                        if ((funct7 == `F7_BASE) ||
                            (funct7 == `F7_SUB_SRA) ||
                            (funct7 == `F7_M_EXT)) begin
                            reg_write  = 1'b1;
                            alu_ctrl   = funct3;
                            funct7_out = funct7;
                        end
                        else begin
                            illegal_instr = 1'b1;
                        end
                    end

                    default: begin
                        illegal_instr = 1'b1;
                    end
                endcase
            end

            //====================================================================
            // I-TYPE REGISTER-IMMEDIATE OPERATIONS
            //   ADDI, SLLI, SLTI, SLTIU, XORI, SRLI, SRAI, ORI, ANDI
            //====================================================================
            `OP_OP_IMM: begin
                alu_a_sel = `ASEL_RS1;
                alu_src   = 1'b1;
                wb_sel    = `WB_ALU;

                case (funct3)
                    `FN_ADD_SUB,
                    `FN_SLT,
                    `FN_SLTU,
                    `FN_XOR,
                    `FN_OR,
                    `FN_AND: begin
                        // Standard I-type arithmetic/logical immediates
                        // funct7 is not semantically used here beyond legality checks.
                        reg_write  = 1'b1;
                        alu_ctrl   = funct3;
                        funct7_out = `F7_BASE;
                    end

                    `FN_SLL: begin
                        // SLLI requires funct7 = 0000000 in RV32I
                        if (funct7 == `F7_BASE) begin
                            reg_write  = 1'b1;
                            alu_ctrl   = funct3;
                            funct7_out = funct7;
                        end
                        else begin
                            illegal_instr = 1'b1;
                        end
                    end

                    `FN_SRL_SRA: begin
                        // SRLI -> 0000000
                        // SRAI -> 0100000
                        if ((funct7 == `F7_BASE) || (funct7 == `F7_SUB_SRA)) begin
                            reg_write  = 1'b1;
                            alu_ctrl   = funct3;
                            funct7_out = funct7;
                        end
                        else begin
                            illegal_instr = 1'b1;
                        end
                    end

                    default: begin
                        illegal_instr = 1'b1;
                    end
                endcase
            end

            //====================================================================
            // LOADS
            //   LB, LH, LW, LBU, LHU
            //====================================================================
            `OP_LOAD: begin
                alu_a_sel = `ASEL_RS1;
                alu_src   = 1'b1;
                wb_sel    = `WB_MEM;
                alu_ctrl  = `FN_ADD_SUB;

                case (funct3)
                    `LD_LB,
                    `LD_LH,
                    `LD_LW,
                    `LD_LBU,
                    `LD_LHU: begin
                        reg_write = 1'b1;
                        mem_read  = 1'b1;
                    end

                    default: begin
                        illegal_instr = 1'b1;
                    end
                endcase
            end

            //====================================================================
            // STORES
            //   SB, SH, SW
            //====================================================================
            `OP_STORE: begin
                alu_a_sel = `ASEL_RS1;
                alu_src   = 1'b1;
                alu_ctrl  = `FN_ADD_SUB;

                case (funct3)
                    `ST_SB,
                    `ST_SH,
                    `ST_SW: begin
                        mem_write = 1'b1;
                    end

                    default: begin
                        illegal_instr = 1'b1;
                    end
                endcase
            end

            //====================================================================
            // BRANCHES
            //   BEQ, BNE, BLT, BGE, BLTU, BGEU
            //====================================================================
            `OP_BRANCH: begin
                alu_a_sel = `ASEL_RS1;
                alu_src   = 1'b0;

                case (funct3)
                    `BR_BEQ,
                    `BR_BNE,
                    `BR_BLT,
                    `BR_BGE,
                    `BR_BLTU,
                    `BR_BGEU: begin
                        branch   = 1'b1;
                        alu_ctrl = funct3;
                    end

                    default: begin
                        illegal_instr = 1'b1;
                    end
                endcase
            end

            //====================================================================
            // JAL
            //====================================================================
            `OP_JAL: begin
                reg_write = 1'b1;
                jump      = 1'b1;
                wb_sel    = `WB_PC4;
            end

            //====================================================================
            // JALR
            //   Standard RV32I requires funct3 = 000
            //====================================================================
            `OP_JALR: begin
                if (funct3 == `JALR_F3) begin
                    reg_write  = 1'b1;
                    jalr       = 1'b1;
                    alu_a_sel  = `ASEL_RS1;
                    alu_src    = 1'b1;
                    wb_sel     = `WB_PC4;
                    alu_ctrl   = `FN_ADD_SUB;
                    funct7_out = `F7_BASE;
                end
                else begin
                    illegal_instr = 1'b1;
                end
            end

            //====================================================================
            // LUI
            //   rd = imm
            //   Implemented in datapath as 0 + imm
            //====================================================================
            `OP_LUI: begin
                reg_write  = 1'b1;
                alu_a_sel  = `ASEL_ZERO;
                alu_src    = 1'b1;
                wb_sel     = `WB_ALU;
                alu_ctrl   = `FN_ADD_SUB;
                funct7_out = `F7_BASE;
            end

            //====================================================================
            // AUIPC
            //   rd = pc + imm
            //====================================================================
            `OP_AUIPC: begin
                reg_write  = 1'b1;
                alu_a_sel  = `ASEL_PC;
                alu_src    = 1'b1;
                wb_sel     = `WB_ALU;
                alu_ctrl   = `FN_ADD_SUB;
                funct7_out = `F7_BASE;
            end

            //====================================================================
            // UNSUPPORTED / ILLEGAL OPCODE
            //====================================================================
            default: begin
                illegal_instr = 1'b1;
            end

        endcase

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