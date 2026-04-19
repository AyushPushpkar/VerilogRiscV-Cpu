//================================================================================
// Immediate Generator - RV32I Standard Formats
//================================================================================
// Decodes and constructs 32-bit immediates from standard RV32I instruction
// formats.
//
// SUPPORTED IMMEDIATE TYPES:
//   I-type : LOAD, OP-IMM, JALR
//   S-type : STORE
//   B-type : BRANCH
//   U-type : LUI, AUIPC
//   J-type : JAL
//
// DESIGN NOTES:
//   - All outputs are 32-bit
//   - I/S/B/J immediates are sign-extended
//   - U-type immediates place bits [31:12] in the upper 20 bits and clear
//     the lower 12 bits
//   - B-type and J-type include the implicit low zero bit required by RV32I
//================================================================================

`timescale 1ns/1ns
`include "defines.v"

module imm_gen (
    input  [31:0] instruction,
    output reg [31:0] imm_out
);

    //========================================================================
    // OPCODE EXTRACTION
    //========================================================================
    wire [6:0] opcode = instruction[6:0];

    always @(*) begin
        case (opcode)

            //================================================================
            // I-TYPE
            //   LOAD, OP-IMM, JALR
            //
            // Layout:
            //   imm[11:0] = instruction[31:20]
            //================================================================
            `OP_LOAD,
            `OP_OP_IMM,
            `OP_JALR: begin
                imm_out = {{20{instruction[31]}}, instruction[31:20]};
            end

            //================================================================
            // S-TYPE
            //   STORE
            //
            // Layout:
            //   imm[11:5] = instruction[31:25]
            //   imm[4:0]  = instruction[11:7]
            //================================================================
            `OP_STORE: begin
                imm_out = {{20{instruction[31]}},
                           instruction[31:25],
                           instruction[11:7]};
            end

            //================================================================
            // B-TYPE
            //   BRANCH
            //
            // Layout:
            //   imm[12]   = instruction[31]
            //   imm[11]   = instruction[7]
            //   imm[10:5] = instruction[30:25]
            //   imm[4:1]  = instruction[11:8]
            //   imm[0]    = 0
            //================================================================
            `OP_BRANCH: begin
                imm_out = {{19{instruction[31]}},
                           instruction[31],
                           instruction[7],
                           instruction[30:25],
                           instruction[11:8],
                           1'b0};
            end

            //================================================================
            // U-TYPE
            //   LUI, AUIPC
            //
            // Layout:
            //   imm[31:12] = instruction[31:12]
            //   imm[11:0]  = 0
            //================================================================
            `OP_LUI,
            `OP_AUIPC: begin
                imm_out = {instruction[31:12], 12'b0};
            end

            //================================================================
            // J-TYPE
            //   JAL
            //
            // Layout:
            //   imm[20]    = instruction[31]
            //   imm[19:12] = instruction[19:12]
            //   imm[11]    = instruction[20]
            //   imm[10:1]  = instruction[30:21]
            //   imm[0]     = 0
            //================================================================
            `OP_JAL: begin
                imm_out = {{11{instruction[31]}},
                           instruction[31],
                           instruction[19:12],
                           instruction[20],
                           instruction[30:21],
                           1'b0};
            end

            //================================================================
            // DEFAULT
            //================================================================
            default: begin
                imm_out = 32'b0;
            end

        endcase
    end

endmodule