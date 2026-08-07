`timescale 1ns/1ns

//============================================================
// ALU compliance test
//
// Differential test of alu.v against an independent model
// derived from the RISC-V spec (RV64I base, RV64M mul/div
// including the mandated divide-by-zero and signed-overflow
// results, and the RV64 *W word ops).
//
// Vectors come from tools/gen_alu_vectors.py, which does not
// read the RTL - it implements the spec from scratch.
//============================================================

module tb_alu_compliance;

    localparam MAX_VEC = 9000;
    localparam FIELDS  = 6;   // f3, f7, is_word, A, B, expected

    reg  [63:0] A, B;
    reg  [2:0]  funct3;
    reg  [6:0]  funct7;
    reg         is_word;
    wire [63:0] result;
    wire        zero, lt, ltu;

    reg [63:0] flat [0:FIELDS*MAX_VEC-1];

    integer n_vec, i, errors;
    reg [63:0] expected;

    alu dut (
        .A          (A),
        .B          (B),
        .funct3     (funct3),
        .funct7     (funct7),
        .is_word_op (is_word),
        .result     (result),
        .zero       (zero),
        .lt         (lt),
        .ltu        (ltu)
    );

    initial begin
        for (i = 0; i < FIELDS*MAX_VEC; i = i + 1)
            flat[i] = 64'hXXXXXXXX_XXXXXXXX;

        $readmemh("alu_vec.txt", flat);

        n_vec  = 0;
        errors = 0;
        for (i = 0; i < MAX_VEC; i = i + 1)
            if (flat[FIELDS*i] !== 64'hXXXXXXXX_XXXXXXXX)
                n_vec = n_vec + 1;

        $display("================================================");
        $display("ALU COMPLIANCE TEST (RV64I + RV64M + *W)");
        $display("================================================");
        $display("Vectors from an independent spec-derived model.");
        $display("Loaded %0d vectors.", n_vec);
        $display("------------------------------------------------");

        for (i = 0; i < n_vec; i = i + 1) begin
            funct3   = flat[FIELDS*i + 0][2:0];
            funct7   = flat[FIELDS*i + 1][6:0];
            is_word  = flat[FIELDS*i + 2][0];
            A        = flat[FIELDS*i + 3];
            B        = flat[FIELDS*i + 4];
            expected = flat[FIELDS*i + 5];
            #1;

            if (result !== expected) begin
                errors = errors + 1;
                if (errors <= 15)
                    $display("FAIL f3=%03b f7=%07b w=%0b A=0x%016h B=0x%016h  rtl=0x%016h  spec=0x%016h",
                             funct3, funct7, is_word, A, B, result, expected);
            end
        end

        $display("------------------------------------------------");
        $display("CHECKS: %0d   ERRORS: %0d", n_vec, errors);
        if (errors == 0)
            $display("RESULT: ALU MATCHES RISC-V SPEC");
        else
            $display("RESULT: ALU DEVIATES FROM SPEC");
        $display("================================================");
        $finish;
    end

endmodule
