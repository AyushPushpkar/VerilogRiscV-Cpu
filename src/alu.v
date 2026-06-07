//================================================================================
// ALU - RV64I + RV64M + Selected B-Extension Operations
//================================================================================
// Performs arithmetic, logical, comparison, shift, RV64M, and selected
// bit-manipulation operations.
//
// SUPPORTED RV64 WORD OPERATIONS:
//   ADDW, SUBW
//   SLLW, SRLW, SRAW
//   ADDIW, SLLIW, SRLIW, SRAIW
// SUPPORTED RV64I OPERATIONS:
//   ADD, SUB
//   AND, OR, XOR
//   SLL, SRL, SRA
//   SLT, SLTU
//
// SUPPORTED RV64M OPERATIONS:
//   MUL, MULH, MULHSU, MULHU
//   DIV, DIVU
//   REM, REMU
//
// SUPPORTED SELECTED B-EXTENSION OPERATIONS:
//   ANDN, ORN, XNOR
//   ROL, ROR
//
// ADDITIONAL OUTPUTS:
//   zero : A == B
//   lt   : signed(A) < signed(B)
//   ltu  : unsigned(A) < unsigned(B)
//
// DESIGN NOTES:
//   - Uses funct3 + funct7 as execution qualifiers
//   - Expects control_unit to block unsupported instruction classes
//   - Still performs tighter internal legality checks for operation variants
//   - Includes RV64M corner-case handling for DIV / REM overflow
//================================================================================

`timescale 1ns/1ns
`include "defines.v"

module alu #(
    parameter XLEN      = 64,//  register width
    parameter OP_WIDTH   = 3//  funct3 width
)(
    input  [XLEN-1:0] A,// source operand A
    input  [XLEN-1:0] B,// source operand B
    input  [OP_WIDTH-1:0]   funct3,
    input  [6:0]            funct7,
    input                   is_word_op, // New input to indicate 32-bit word operations
    output reg [XLEN-1:0] result,
    output                      zero,
    output                      lt,
    output                      ltu
);

    //========================================================================
    // LOCAL CONSTANTS
    //========================================================================
    localparam SHIFT_WIDTH = $clog2(XLEN); // Number of bits needed to represent shift amounts

    // INT_MIN for signed overflow corner cases in DIV / REM.
    localparam [XLEN-1:0] INT_MIN = {1'b1, {(XLEN-1){1'b0}}};
   

   //========================================================================
// RV64 WORD OPERATION HELPERS
//========================================================================
// W-type instructions operate on lower 32 bits and sign-extend to XLEN.
      wire [31:0] A_word = A[31:0];
      wire [31:0] B_word = B[31:0];

      wire signed [31:0] A_word_s = $signed(A_word);

      wire [4:0] word_shamt = B[4:0];

     reg [31:0] word_result;
    //========================================================================
    // SIGNED / UNSIGNED VIEWS
    //========================================================================
    wire signed [XLEN-1:0] A_s = $signed(A);
    wire signed [XLEN-1:0] B_s = $signed(B);

    //========================================================================
    // MULTIPLY INTERMEDIATES
    //========================================================================
    wire signed [2*XLEN-1:0] mul_ss =
        $signed(A) * $signed(B);

    wire        [2*XLEN-1:0] mul_uu =
        A * B;

    wire signed [XLEN:0] A_s_ext = {A[XLEN-1], A};
    wire signed [XLEN:0] B_u_ext = {1'b0, B};

   wire signed [2*(XLEN+1)-1:0] mul_su_ext =
      A_s_ext * B_u_ext;
    

    //========================================================================
    // MAIN EXECUTION LOGIC
    //========================================================================
    always @(*) begin
        result = {XLEN{1'b0}};
       word_result = 32'b0;
       
        //====================================================================
    // RV64 WORD OPERATIONS
    // ADDW, SUBW, SLLW, SRLW, SRAW
    // ADDIW, SLLIW, SRLIW, SRAIW
    //====================================================================
    if (is_word_op) begin
        case (funct3)

            // ADDW / SUBW / ADDIW
            `FN_ADD_SUB: begin
                case (funct7)
                    `F7_BASE: begin
                        word_result = A_word + B_word;
                        result = {{(XLEN-32){word_result[31]}}, word_result};
                    end

                    `F7_SUB_SRA: begin
                        word_result = A_word - B_word;
                        result = {{(XLEN-32){word_result[31]}}, word_result};
                    end

                    default: begin
                        result = {XLEN{1'b0}};
                    end
                endcase
            end

            // SLLW / SLLIW
            `FN_SLL: begin
                if (funct7 == `F7_BASE) begin
                    word_result = A_word << word_shamt;
                    result = {{(XLEN-32){word_result[31]}}, word_result};
                end
                else begin
                    result = {XLEN{1'b0}};
                end
            end

            // SRLW / SRAW / SRLIW / SRAIW
            `FN_SRL_SRA: begin
                case (funct7)
                    `F7_BASE: begin
                        word_result = A_word >> word_shamt;
                        result = {{(XLEN-32){word_result[31]}}, word_result};
                    end

                    `F7_SUB_SRA: begin
                        word_result = A_word_s >>> word_shamt;
                        result = {{(XLEN-32){word_result[31]}}, word_result};
                    end

                    default: begin
                        result = {XLEN{1'b0}};
                    end
                endcase
            end

            default: begin
                result = {XLEN{1'b0}};
            end
        endcase
    end

    //====================================================================
    // RV64M OPERATIONS
    //====================================================================
    else if (funct7 == `F7_M_EXT) begin
            case (funct3)

                //============================================================
                // MULTIPLY FAMILY
                //============================================================
                `FN_MUL: begin
                    result = mul_ss[XLEN-1:0];
                end

                `FN_MULH: begin
                    result = mul_ss[2*XLEN-1:XLEN];
                end

                `FN_MULHSU: begin
                    result = mul_su_ext[2*XLEN-1:XLEN];
                end

                `FN_MULHU: begin
                    result = mul_uu[2*XLEN-1:XLEN];
                end

                //============================================================
                // DIVISION FAMILY
                //============================================================
                `FN_DIV: begin
                    // RV64M rules:
                    //   divisor = 0        -> quotient = -1 (all 1s)
                    //   INT_MIN / -1       -> INT_MIN
                    if (B == {XLEN{1'b0}}) begin
                        result = {XLEN{1'b1}};
                    end
                    else if ((A == INT_MIN) && (B == {XLEN{1'b1}})) begin
                        result = INT_MIN;
                    end
                    else begin
                        result = A_s / B_s;
                    end
                end

                `FN_DIVU: begin
                    // RV64M rules:
                    //   divisor = 0 -> quotient = all 1s
                    if (B == {XLEN{1'b0}}) begin
                        result = {XLEN{1'b1}};
                    end
                    else begin
                        result = A / B;
                    end
                end

                //============================================================
                // REMAINDER FAMILY
                //============================================================
                `FN_REM: begin
                    // RV64M rules:
                    //   divisor = 0        -> remainder = dividend
                    //   INT_MIN % -1       -> 0
                    if (B == {XLEN{1'b0}}) begin
                        result = A;
                    end
                    else if ((A == INT_MIN) && (B == {XLEN{1'b1}})) begin
                        result = {XLEN{1'b0}};
                    end
                    else begin
                        result = A_s % B_s;
                    end
                end

                `FN_REMU: begin
                    // RV64M rules:
                    //   divisor = 0 -> remainder = dividend
                    if (B == {XLEN{1'b0}}) begin
                        result = A;
                    end
                    else begin
                        result = A % B;
                    end
                end

                default: begin
                    result = {XLEN{1'b0}};
                end
            endcase
        end

        //====================================================================
        // RV64I BASE INTEGER OPERATIONS
        //====================================================================
        else begin
            case (funct3)

                //============================================================
                // ADD / SUB
                // Valid funct7:
                //   F7_BASE    -> ADD
                //   F7_SUB_SRA -> SUB
                //============================================================
                `FN_ADD_SUB: begin
                    case (funct7)
                        `F7_BASE:    result = A + B;
                        `F7_SUB_SRA: result = A - B;
                        default:     result = {XLEN{1'b0}};
                    endcase
                end

                //============================================================
                // SHIFT LEFT
                // Valid funct7:
                //   F7_BASE -> SLL / SLLI
                //============================================================
                `FN_SLL: begin
                    case(funct7)
                        `F7_BASE:begin
                            result = A << B[SHIFT_WIDTH-1:0];
                        end

                        //B-extension :ROL
                            `F7_ROT: begin
                                if (B[SHIFT_WIDTH-1:0] == 0) begin
                                    result = A;
                                end
                                    else begin
                                      result = (A << B[SHIFT_WIDTH-1:0]) |
                                        (A >> (XLEN - B[SHIFT_WIDTH-1:0]));
                                end
                            end
                        default: begin
                            result = {XLEN{1'b0}};
                        end
                    endcase
                end

                //============================================================
                // SET LESS THAN (SIGNED)
                //============================================================
                `FN_SLT: begin
                    if (funct7 == `F7_BASE)
                        result = (A_s < B_s) ? {{(XLEN-1){1'b0}}, 1'b1}
                                             : {XLEN{1'b0}};
                    else
                        result = {XLEN{1'b0}};
                end

                //============================================================
                // SET LESS THAN (UNSIGNED)
                //============================================================
                `FN_SLTU: begin
                    if (funct7 == `F7_BASE)
                        result = (A < B) ? {{(XLEN-1){1'b0}}, 1'b1}
                                         : {XLEN{1'b0}};
                    else
                        result = {XLEN{1'b0}};
                end

                //============================================================
                // XOR
                //============================================================
                `FN_XOR: begin
                    case (funct7)
                        `F7_BASE: begin
                            result = A ^ B;
                        end
                        //B-extension :XNOR
                        `F7_XNOR: begin
                            result = ~(A ^ B);
                        end
                        default: begin
                            result = {XLEN{1'b0}};
                        end
                    endcase
                end

                //============================================================
                // SHIFT RIGHT
                // Valid funct7:
                //   F7_BASE    -> SRL / SRLI
                //   F7_SUB_SRA -> SRA / SRAI
                //============================================================
                `FN_SRL_SRA: begin
                    case (funct7)
                        `F7_BASE: begin
                            result = A >> B[SHIFT_WIDTH-1:0];
                        end

                        `F7_SUB_SRA: begin
                            result = A_s >>> B[SHIFT_WIDTH-1:0];
                        end
                    //B-extension : ROR
                        `F7_ROT: begin
                            if (B[SHIFT_WIDTH-1:0] == 0) begin
                                result = A;
                            end
                            else begin
                                result = (A >> B[SHIFT_WIDTH-1:0]) |
                                     (A << (XLEN - B[SHIFT_WIDTH-1:0]));
                        end
                    end
                        default: begin
                            result = {XLEN{1'b0}};
                        end
                    endcase
                end

                //============================================================
                // OR
                //============================================================
                `FN_OR: begin
                  case(funct7)
                  `F7_BASE: begin
                    result = A | B; 
                    end
                    //B-extension : ORN
                    `F7_ORN: begin
                        result = A | ~B;
                    end
                    default: begin
                        result = {XLEN{1'b0}};
                    end
                  endcase
                end

                //============================================================
                // AND
                //============================================================
                `FN_AND: begin
                    case (funct7)
                        `F7_BASE: begin
                            result = A & B;
                        end
                        //B-extension : ANDN
                        `F7_ANDN: begin
                            result = A & ~B;
                        end
                        default: begin
                            result = {XLEN{1'b0}};
                        end
                    endcase
                end

                default: begin
                    result = {XLEN{1'b0}};
                end
            endcase
        end
    end

    //========================================================================
    // COMPARISON FLAGS
    //========================================================================
    assign zero = (A == B);
    assign lt   = (A_s < B_s);
    assign ltu  = (A < B);

endmodule