//================================================================================
// ALU - RV32I + RV32M (Single-Cycle CPU, Tightened Decode)
//================================================================================
// Performs arithmetic, logical, comparison, shift, and RV32M operations.
//
// SUPPORTED RV32I OPERATIONS:
//   ADD, SUB
//   AND, OR, XOR
//   SLL, SRL, SRA
//   SLT, SLTU
//
// SUPPORTED RV32M OPERATIONS:
//   MUL, MULH, MULHSU, MULHU
//   DIV, DIVU
//   REM, REMU
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
//   - Includes RV32M corner-case handling for DIV / REM overflow
//================================================================================

`timescale 1ns/1ns
`include "defines.v"

module alu #(
    parameter DATA_WIDTH = 32,
    parameter OP_WIDTH   = 3
)(
    input  [DATA_WIDTH-1:0] A,
    input  [DATA_WIDTH-1:0] B,
    input  [OP_WIDTH-1:0]   funct3,
    input  [6:0]            funct7,

    output reg [DATA_WIDTH-1:0] result,
    output                      zero,
    output                      lt,
    output                      ltu
);

    //========================================================================
    // LOCAL CONSTANTS
    //========================================================================
    localparam SHIFT_WIDTH = $clog2(DATA_WIDTH);

    // INT_MIN for signed overflow corner cases in DIV / REM.
    localparam [DATA_WIDTH-1:0] INT_MIN = {1'b1, {(DATA_WIDTH-1){1'b0}}};

    //========================================================================
    // SIGNED / UNSIGNED VIEWS
    //========================================================================
    wire signed [DATA_WIDTH-1:0] A_s = $signed(A);
    wire signed [DATA_WIDTH-1:0] B_s = $signed(B);

    //========================================================================
    // MULTIPLY INTERMEDIATES
    //========================================================================
    wire signed [2*DATA_WIDTH-1:0] mul_ss =
        $signed(A) * $signed(B);

    wire        [2*DATA_WIDTH-1:0] mul_uu =
        A * B;

    wire signed [2*DATA_WIDTH-1:0] mul_su =
        $signed(A) * $signed({1'b0, B});

    //========================================================================
    // MAIN EXECUTION LOGIC
    //========================================================================
    always @(*) begin
        result = {DATA_WIDTH{1'b0}};

        //====================================================================
        // RV32M OPERATIONS
        //====================================================================
        if (funct7 == `F7_M_EXT) begin
            case (funct3)

                //============================================================
                // MULTIPLY FAMILY
                //============================================================
                `FN_MUL: begin
                    result = mul_ss[DATA_WIDTH-1:0];
                end

                `FN_MULH: begin
                    result = mul_ss[2*DATA_WIDTH-1:DATA_WIDTH];
                end

                `FN_MULHSU: begin
                    result = mul_su[2*DATA_WIDTH-1:DATA_WIDTH];
                end

                `FN_MULHU: begin
                    result = mul_uu[2*DATA_WIDTH-1:DATA_WIDTH];
                end

                //============================================================
                // DIVISION FAMILY
                //============================================================
                `FN_DIV: begin
                    // RV32M rules:
                    //   divisor = 0        -> quotient = -1 (all 1s)
                    //   INT_MIN / -1       -> INT_MIN
                    if (B == {DATA_WIDTH{1'b0}}) begin
                        result = {DATA_WIDTH{1'b1}};
                    end
                    else if ((A == INT_MIN) && (B == {DATA_WIDTH{1'b1}})) begin
                        result = INT_MIN;
                    end
                    else begin
                        result = A_s / B_s;
                    end
                end

                `FN_DIVU: begin
                    // RV32M rules:
                    //   divisor = 0 -> quotient = all 1s
                    if (B == {DATA_WIDTH{1'b0}}) begin
                        result = {DATA_WIDTH{1'b1}};
                    end
                    else begin
                        result = A / B;
                    end
                end

                //============================================================
                // REMAINDER FAMILY
                //============================================================
                `FN_REM: begin
                    // RV32M rules:
                    //   divisor = 0        -> remainder = dividend
                    //   INT_MIN % -1       -> 0
                    if (B == {DATA_WIDTH{1'b0}}) begin
                        result = A;
                    end
                    else if ((A == INT_MIN) && (B == {DATA_WIDTH{1'b1}})) begin
                        result = {DATA_WIDTH{1'b0}};
                    end
                    else begin
                        result = A_s % B_s;
                    end
                end

                `FN_REMU: begin
                    // RV32M rules:
                    //   divisor = 0 -> remainder = dividend
                    if (B == {DATA_WIDTH{1'b0}}) begin
                        result = A;
                    end
                    else begin
                        result = A % B;
                    end
                end

                default: begin
                    result = {DATA_WIDTH{1'b0}};
                end
            endcase
        end

        //====================================================================
        // RV32I BASE INTEGER OPERATIONS
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
                        default:     result = {DATA_WIDTH{1'b0}};
                    endcase
                end

                //============================================================
                // SHIFT LEFT
                // Valid funct7:
                //   F7_BASE -> SLL / SLLI
                //============================================================
                `FN_SLL: begin
                    if (funct7 == `F7_BASE)
                        result = A << B[SHIFT_WIDTH-1:0];
                    else
                        result = {DATA_WIDTH{1'b0}};
                end

                //============================================================
                // SET LESS THAN (SIGNED)
                //============================================================
                `FN_SLT: begin
                    if (funct7 == `F7_BASE)
                        result = (A_s < B_s) ? {{(DATA_WIDTH-1){1'b0}}, 1'b1}
                                             : {DATA_WIDTH{1'b0}};
                    else
                        result = {DATA_WIDTH{1'b0}};
                end

                //============================================================
                // SET LESS THAN (UNSIGNED)
                //============================================================
                `FN_SLTU: begin
                    if (funct7 == `F7_BASE)
                        result = (A < B) ? {{(DATA_WIDTH-1){1'b0}}, 1'b1}
                                         : {DATA_WIDTH{1'b0}};
                    else
                        result = {DATA_WIDTH{1'b0}};
                end

                //============================================================
                // XOR
                //============================================================
                `FN_XOR: begin
                    if (funct7 == `F7_BASE)
                        result = A ^ B;
                    else
                        result = {DATA_WIDTH{1'b0}};
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

                        default: begin
                            result = {DATA_WIDTH{1'b0}};
                        end
                    endcase
                end

                //============================================================
                // OR
                //============================================================
                `FN_OR: begin
                    if (funct7 == `F7_BASE)
                        result = A | B;
                    else
                        result = {DATA_WIDTH{1'b0}};
                end

                //============================================================
                // AND
                //============================================================
                `FN_AND: begin
                    if (funct7 == `F7_BASE)
                        result = A & B;
                    else
                        result = {DATA_WIDTH{1'b0}};
                end

                default: begin
                    result = {DATA_WIDTH{1'b0}};
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