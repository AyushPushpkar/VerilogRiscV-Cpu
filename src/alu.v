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
    wire signed [2*DATA_WIDTH-1:0] mul_ss = $signed(A) * $signed(B);
    wire        [2*DATA_WIDTH-1:0] mul_uu = A * B;
    wire signed [2*DATA_WIDTH-1:0] mul_su = $signed(A) * $signed({1'b0, B});

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
                `FN_MUL:    result = mul_ss[DATA_WIDTH-1:0];
                `FN_MULH:   result = mul_ss[2*DATA_WIDTH-1:DATA_WIDTH];
                `FN_MULHSU: result = mul_su[2*DATA_WIDTH-1:DATA_WIDTH];
                `FN_MULHU:  result = mul_uu[2*DATA_WIDTH-1:DATA_WIDTH];

                //============================================================
                // DIVISION FAMILY
                // RV32M rules:
                //   divisor = 0      -> quotient = all 1s
                //   INT_MIN / -1     -> INT_MIN
                //============================================================
                `FN_DIV: begin
                    if (B == {DATA_WIDTH{1'b0}})
                        result = {DATA_WIDTH{1'b1}};
                    else if ((A == INT_MIN) && (B == {DATA_WIDTH{1'b1}}))
                        result = INT_MIN;
                    else
                        result = A_s / B_s;
                end

                `FN_DIVU: begin
                    // RV32M: divisor = 0 -> quotient = all 1s
                    if (B == {DATA_WIDTH{1'b0}})
                        result = {DATA_WIDTH{1'b1}};
                    else
                        result = A / B;
                end

                //============================================================
                // REMAINDER FAMILY
                // RV32M rules:
                //   divisor = 0      -> remainder = dividend
                //   INT_MIN % -1     -> 0
                //============================================================
                `FN_REM: begin
                    if (B == {DATA_WIDTH{1'b0}})
                        result = A;
                    else if ((A == INT_MIN) && (B == {DATA_WIDTH{1'b1}}))
                        result = {DATA_WIDTH{1'b0}};
                    else
                        result = A_s % B_s;
                end

                `FN_REMU: begin
                    // RV32M: divisor = 0 -> remainder = dividend
                    if (B == {DATA_WIDTH{1'b0}})
                        result = A;
                    else
                        result = A % B;
                end

                default: result = {DATA_WIDTH{1'b0}};
            endcase
        end

        //====================================================================
        // RV32I BASE INTEGER OPERATIONS
        //====================================================================
        else begin
            case (funct3)

                //============================================================
                // ADD / SUB
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
                // SHIFT LEFT — SLL / SLLI
                //   F7_BASE -> SLL
                //   F7_ROT  -> ROL (B-extension)
                //============================================================
                `FN_SLL: begin
                    case (funct7)
                        `F7_BASE: result = A << B[SHIFT_WIDTH-1:0];

                        `F7_ROT: begin
                            if (B[SHIFT_WIDTH-1:0] == 0)
                                result = A;
                            else
                                result = (A << B[SHIFT_WIDTH-1:0]) |
                                         (A >> (DATA_WIDTH - B[SHIFT_WIDTH-1:0]));
                        end

                        default: result = {DATA_WIDTH{1'b0}};
                    endcase
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
                //   F7_BASE -> XOR
                //   F7_XNOR -> XNOR (B-extension)
                //============================================================
                `FN_XOR: begin
                    case (funct7)
                        `F7_BASE: result = A ^ B;
                        `F7_XNOR: result = ~(A ^ B);
                        default:  result = {DATA_WIDTH{1'b0}};
                    endcase
                end

                //============================================================
                // SHIFT RIGHT — SRL / SRLI / SRA / SRAI
                //   F7_BASE    -> SRL
                //   F7_SUB_SRA -> SRA
                //   F7_ROT     -> ROR (B-extension)
                //============================================================
                `FN_SRL_SRA: begin
                    case (funct7)
                        `F7_BASE:    result = A >> B[SHIFT_WIDTH-1:0];
                        `F7_SUB_SRA: result = A_s >>> B[SHIFT_WIDTH-1:0];

                        `F7_ROT: begin
                            if (B[SHIFT_WIDTH-1:0] == 0)
                                result = A;
                            else
                                result = (A >> B[SHIFT_WIDTH-1:0]) |
                                         (A << (DATA_WIDTH - B[SHIFT_WIDTH-1:0]));
                        end

                        default: result = {DATA_WIDTH{1'b0}};
                    endcase
                end

                //============================================================
                // OR
                //   F7_BASE -> OR
                //   F7_ORN  -> ORN (B-extension)
                //============================================================
                `FN_OR: begin
                    case (funct7)
                        `F7_BASE: result = A | B;
                        `F7_ORN:  result = A | ~B;
                        default:  result = {DATA_WIDTH{1'b0}};
                    endcase
                end

                //============================================================
                // AND
                //   F7_BASE -> AND
                //   F7_ANDN -> ANDN (B-extension)
                //============================================================
                `FN_AND: begin
                    case (funct7)
                        `F7_BASE: result = A & B;
                        `F7_ANDN: result = A & ~B;
                        default:  result = {DATA_WIDTH{1'b0}};
                    endcase
                end

                default: result = {DATA_WIDTH{1'b0}};
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