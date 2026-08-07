`timescale 1ns/1ns
`include "defines.v"

//============================================================
// Branch comparison compliance test
//
// Drives the real alu.v comparison outputs (zero / lt / ltu)
// through the SAME take_branch expression cpu_top.v uses, and
// checks the decision against an independent spec model.
//
// The bug class this targets: wiring BLT to the unsigned
// comparator (or BLTU to the signed one). That passes every
// non-negative test and fails only across the sign boundary,
// so the vectors deliberately straddle it.
//============================================================

module tb_branch_compliance;

    localparam MAX_VEC = 2000;
    localparam FIELDS  = 4;   // funct3, A, B, expected_taken

    reg  [63:0] A, B;
    reg  [2:0]  funct3;
    wire [63:0] alu_result;
    wire        alu_zero, alu_lt, alu_ltu;

    reg [63:0] flat [0:FIELDS*MAX_VEC-1];

    integer n_vec, i, errors;
    reg expected;
    reg taken;

    // The ALU's comparison outputs are computed from A and B directly, not
    // from the selected operation, so funct3 here is the BRANCH funct3.
    alu dut (
        .A          (A),
        .B          (B),
        .funct3     (funct3),
        .funct7     (7'b0000000),
        .is_word_op (1'b0),
        .result     (alu_result),
        .zero       (alu_zero),
        .lt         (alu_lt),
        .ltu        (alu_ltu)
    );

    // EXACTLY the expression from cpu_top.v (section 11), minus branch_safe.
    // If this diverges from cpu_top, the test is worthless - keep in sync.
    always @(*) begin
        taken =
            (funct3 == `BR_BEQ  &&  alu_zero) ||
            (funct3 == `BR_BNE  && !alu_zero) ||
            (funct3 == `BR_BLT  &&  alu_lt)   ||
            (funct3 == `BR_BGE  && !alu_lt)   ||
            (funct3 == `BR_BLTU &&  alu_ltu)  ||
            (funct3 == `BR_BGEU && !alu_ltu);
    end

    initial begin
        for (i = 0; i < FIELDS*MAX_VEC; i = i + 1)
            flat[i] = 64'hXXXXXXXX_XXXXXXXX;

        $readmemh("branch_vec.txt", flat);

        n_vec  = 0;
        errors = 0;
        for (i = 0; i < MAX_VEC; i = i + 1)
            if (flat[FIELDS*i] !== 64'hXXXXXXXX_XXXXXXXX)
                n_vec = n_vec + 1;

        $display("================================================");
        $display("BRANCH COMPARISON COMPLIANCE TEST");
        $display("================================================");
        $display("Vectors from an independent spec-derived model.");
        $display("Loaded %0d vectors.", n_vec);

        if (n_vec >= MAX_VEC)
            $display("WARNING: hit MAX_VEC cap - vectors may be truncated!");

        $display("------------------------------------------------");

        for (i = 0; i < n_vec; i = i + 1) begin
            funct3   = flat[FIELDS*i + 0][2:0];
            A        = flat[FIELDS*i + 1];
            B        = flat[FIELDS*i + 2];
            expected = flat[FIELDS*i + 3][0];
            #1;

            if (taken !== expected) begin
                errors = errors + 1;
                if (errors <= 15)
                    $display("FAIL f3=%03b A=0x%016h B=0x%016h  rtl=%0b  spec=%0b",
                             funct3, A, B, taken, expected);
            end
        end

        $display("------------------------------------------------");
        $display("CHECKS: %0d   ERRORS: %0d", n_vec, errors);
        if (errors == 0)
            $display("RESULT: BRANCH LOGIC MATCHES RISC-V SPEC");
        else
            $display("RESULT: BRANCH LOGIC DEVIATES FROM SPEC");
        $display("================================================");
        $finish;
    end

endmodule
