//================================================================================
// Clean RV64I + RV64M + B-extension ALU (Production Grade)
//================================================================================

`timescale 1ns/1ns
`include "defines.v"

module alu #(
    parameter XLEN = 64,
    parameter OP_WIDTH = 3
)(
    input  [XLEN-1:0] A,
    input  [XLEN-1:0] B,
    input  [OP_WIDTH-1:0] funct3,
    input  [6:0] funct7,
    input              is_word_op,

    output reg [XLEN-1:0] result,
    output                zero,
    output                lt,
    output                ltu
);

    localparam SHIFT_WIDTH = $clog2(XLEN);
    localparam [XLEN-1:0] INT_MIN = {1'b1, {(XLEN-1){1'b0}}};

    wire signed [XLEN-1:0] A_s = $signed(A);
    wire signed [XLEN-1:0] B_s = $signed(B);

    wire [31:0] A_w = A[31:0];
    wire [31:0] B_w = B[31:0];
    wire signed [31:0] A_w_s = $signed(A_w);
    wire signed [31:0] B_w_s = $signed(B_w);
    wire [4:0] shamt_w = B[4:0];

    reg [31:0] wres;

    wire signed [2*XLEN-1:0] mul_ss = $signed(A) * $signed(B);
    wire        [2*XLEN-1:0] mul_uu = A * B;

    wire signed [XLEN:0] A_se = {A[XLEN-1], A};
    wire signed [XLEN:0] B_ue = {1'b0, B};
    wire signed [2*(XLEN+1)-1:0] mul_su = A_se * B_ue;

    always @(*) begin
        result = 0;
        wres   = 0;

        //============================================================
        // RV64 WORD OPERATIONS
        //============================================================
        if (is_word_op) begin
            case (funct3)

                // ADDW / SUBW / MULW
                `FN_ADD_SUB: begin
                    case (funct7)
                        `F7_BASE:    wres = A_w + B_w;
                        `F7_SUB_SRA: wres = A_w - B_w;
                        `F7_M_EXT:   wres = A_w_s * B_w_s;
                        default:     wres = 0;
                    endcase
                end

                // SLLW / SLLIW
                `FN_SLL: begin
                    if (funct7 == `F7_BASE)
                        wres = A_w << shamt_w;
                    else
                        wres = 0;
                end

                // funct3 101 : SRLW (BASE) / SRAW (SUB_SRA) / DIVUW (M_EXT)
                // These share funct3, so funct7 selects the operation.
                `FN_SRL_SRA: begin
                    case (funct7)
                        `F7_BASE:    wres = A_w >> shamt_w;
                        `F7_SUB_SRA: wres = A_w_s >>> shamt_w;
                        `F7_M_EXT:   wres = (B_w == 0) ? 32'hFFFFFFFF : (A_w / B_w); // DIVUW
                        default:     wres = 0;
                    endcase
                end

                // DIVW (funct3 100)
                `FN_DIV: begin
                    if (funct7 == `F7_M_EXT)
                        wres = (B_w == 0) ? 32'hFFFFFFFF :
                               ((A_w == 32'h80000000 && B_w == 32'hFFFFFFFF)
                                ? 32'h80000000 : A_w_s / B_w_s);
                    else wres = 0;
                end

                // REMW
                `FN_REM: begin
                    if (funct7 == `F7_M_EXT)
                        wres = (B_w == 0) ? A_w :
                               ((A_w == 32'h80000000 && B_w == 32'hFFFFFFFF)
                                ? 0 : A_w_s % B_w_s);
                    else wres = 0;
                end

                // REMUW
                `FN_REMU: begin
                    if (funct7 == `F7_M_EXT)
                        wres = (B_w == 0) ? A_w : (A_w % B_w);
                    else wres = 0;
                end

                default: wres = 0;
            endcase

            result = {{(XLEN-32){wres[31]}}, wres};
        end

        //============================================================
        // RV64M (FULL WIDTH)
        //============================================================
        else if (funct7 == `F7_M_EXT) begin
            case (funct3)

                `FN_MUL:    result = mul_ss[XLEN-1:0];
                `FN_MULH:   result = mul_ss[2*XLEN-1:XLEN];
                `FN_MULHSU: result = mul_su[2*XLEN-1:XLEN];
                `FN_MULHU:  result = mul_uu[2*XLEN-1:XLEN];

                `FN_DIV: begin
                    if (B == 0) result = {XLEN{1'b1}};
                    else if (A == INT_MIN && B == {XLEN{1'b1}})
                        result = INT_MIN;
                    else result = A_s / B_s;
                end

                `FN_DIVU: begin
                    result = (B == 0) ? {XLEN{1'b1}} : (A / B);
                end

                `FN_REM: begin
                    if (B == 0) result = A;
                    else if (A == INT_MIN && B == {XLEN{1'b1}})
                        result = 0;
                    else result = A_s % B_s;
                end

                `FN_REMU: begin
                    result = (B == 0) ? A : (A % B);
                end

                default: result = 0;
            endcase
        end

        //============================================================
        // RV64I BASE + B EXTENSION
        //============================================================
        else begin
            case (funct3)

                // ADD / SUB
                `FN_ADD_SUB: begin
                    case (funct7)
                        `F7_BASE:    result = A + B;
                        `F7_SUB_SRA: result = A - B;
                        default:     result = 0;
                    endcase
                end

                // SLL + ROL
                `FN_SLL: begin
                    case (funct7)
                        `F7_BASE: result = A << B[SHIFT_WIDTH-1:0];
                        `F7_ROT:  result = (A << B[SHIFT_WIDTH-1:0]) |
                                           (A >> (XLEN - B[SHIFT_WIDTH-1:0]));
                        default:  result = 0;
                    endcase
                end

                // SLT
                `FN_SLT: result = (A_s < B_s);

                // SLTU
                `FN_SLTU: result = (A < B);

                // XOR + XNOR
                `FN_XOR: begin
                    case (funct7)
                        `F7_BASE: result = A ^ B;
                        `F7_XNOR: result = ~(A ^ B);
                        default:   result = 0;
                    endcase
                end

                // SRL / SRA / ROR
                `FN_SRL_SRA: begin
                    case (funct7)
                        `F7_BASE:    result = A >> B[SHIFT_WIDTH-1:0];
                        `F7_SUB_SRA: result = A_s >>> B[SHIFT_WIDTH-1:0];
                        `F7_ROT:     result = (A >> B[SHIFT_WIDTH-1:0]) |
                                              (A << (XLEN - B[SHIFT_WIDTH-1:0]));
                        default:     result = 0;
                    endcase
                end

                // OR / ORN
                `FN_OR: begin
                    case (funct7)
                        `F7_BASE: result = A | B;
                        `F7_ORN:  result = A | ~B;
                        default:  result = 0;
                    endcase
                end

                // AND / ANDN
                `FN_AND: begin
                    case (funct7)
                        `F7_BASE: result = A & B;
                        `F7_ANDN: result = A & ~B;
                        default:  result = 0;
                    endcase
                end

                default: result = 0;
            endcase
        end
    end

    assign zero = (A == B);
    assign lt   = (A_s < B_s);
    assign ltu  = (A < B);

endmodule