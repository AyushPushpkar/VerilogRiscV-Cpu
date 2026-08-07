`timescale 1ns/1ns

//============================================================
// Matrix tile controller testbench
// Step 6 of the ML RTL order - the last block.
//
// Models the operand source: A and B live in arrays, and the
// testbench packs the requested chunks onto a_data / b_data
// as the DUT drives row / col / k_idx.
//
// Every output element is checked against a software GEMM.
//
// Covers docs/ML_TEST_PLAN.md: 2x2, 4x4, non-square, and tile
// boundary cases (K not a multiple of the lane count).
//============================================================

module tb_matrix_tile;

    localparam DATA_WIDTH = 64;
    localparam ACC_WIDTH  = 128;
    localparam DIM_WIDTH  = 8;
    localparam MAXDIM     = 16;

    localparam [1:0] LANE_8  = 2'd0,
                     LANE_16 = 2'd1,
                     LANE_32 = 2'd2,
                     LANE_64 = 2'd3;

    reg                    clk;
    reg                    rst_n;
    reg                    start;
    reg                    is_signed;
    reg  [1:0]             lane_mode;
    reg  [DIM_WIDTH-1:0]   dim_m, dim_n, dim_k;

    wire [DIM_WIDTH-1:0]   row, col, k_idx;
    reg  [DATA_WIDTH-1:0]  a_data, b_data;

    wire                   c_valid;
    wire [DIM_WIDTH-1:0]   c_row, c_col;
    wire [ACC_WIDTH-1:0]   c_data;
    wire                   busy, done;

    integer checks, errors;
    integer i, j, k;

    // Matrices. Elements are stored as full 64-bit signed values; the packer
    // below narrows them to the active lane width.
    reg signed [63:0] matA [0:MAXDIM-1][0:MAXDIM-1];
    reg signed [63:0] matB [0:MAXDIM-1][0:MAXDIM-1];
    reg signed [63:0] matC_expect [0:MAXDIM-1][0:MAXDIM-1];
    reg               c_seen [0:MAXDIM-1][0:MAXDIM-1];

    matrix_tile #(
        .DATA_WIDTH (DATA_WIDTH),
        .ACC_WIDTH  (ACC_WIDTH),
        .DIM_WIDTH  (DIM_WIDTH)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (start),
        .is_signed (is_signed),
        .lane_mode (lane_mode),
        .dim_m     (dim_m),
        .dim_n     (dim_n),
        .dim_k     (dim_k),
        .row       (row),
        .col       (col),
        .k_idx     (k_idx),
        .a_data    (a_data),
        .b_data    (b_data),
        .c_valid   (c_valid),
        .c_row     (c_row),
        .c_col     (c_col),
        .c_data    (c_data),
        .busy      (busy),
        .done      (done)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    //--------------------------------------------------------
    // Lane count for the active mode.
    //--------------------------------------------------------
    function integer lane_count;
        input [1:0] mode;
        begin
            case (mode)
                LANE_8:  lane_count = 8;
                LANE_16: lane_count = 4;
                LANE_32: lane_count = 2;
                default: lane_count = 1;
            endcase
        end
    endfunction

    function integer lane_bits;
        input [1:0] mode;
        begin
            case (mode)
                LANE_8:  lane_bits = 8;
                LANE_16: lane_bits = 16;
                LANE_32: lane_bits = 32;
                default: lane_bits = 64;
            endcase
        end
    endfunction

    //--------------------------------------------------------
    // OPERAND SUPPLY.
    //
    // The DUT drives row/col/k_idx; we present the packed chunks. Elements
    // past dim_k are packed as ZERO so they contribute nothing to the sum -
    // this is what makes a K that is not a multiple of the lane count work.
    //--------------------------------------------------------
    integer li, kk, nbits, nlanes;
    always @(*) begin
        a_data = {DATA_WIDTH{1'b0}};
        b_data = {DATA_WIDTH{1'b0}};

        nbits  = lane_bits(lane_mode);
        nlanes = lane_count(lane_mode);

        for (li = 0; li < nlanes; li = li + 1) begin
            kk = k_idx + li;
            if (kk < dim_k) begin
                // Lane li holds element k_idx+li, low lane first.
                a_data[li*nbits +: 8] = matA[row][kk][7:0];
                b_data[li*nbits +: 8] = matB[kk][col][7:0];

                if (nbits >= 16) begin
                    a_data[li*nbits + 8 +: 8] = matA[row][kk][15:8];
                    b_data[li*nbits + 8 +: 8] = matB[kk][col][15:8];
                end
                if (nbits >= 32) begin
                    a_data[li*nbits + 16 +: 16] = matA[row][kk][31:16];
                    b_data[li*nbits + 16 +: 16] = matB[kk][col][31:16];
                end
                if (nbits == 64) begin
                    a_data[li*nbits + 32 +: 32] = matA[row][kk][63:32];
                    b_data[li*nbits + 32 +: 32] = matB[kk][col][63:32];
                end
            end
            // else: leave the lane at zero - past the end of k
        end
    end

    //--------------------------------------------------------
    // Software GEMM reference.
    //--------------------------------------------------------
    task compute_expected;
        input integer m, n, kdim;
        integer ii, jj, kx;
        reg signed [63:0] acc;
        begin
            for (ii = 0; ii < m; ii = ii + 1)
                for (jj = 0; jj < n; jj = jj + 1) begin
                    acc = 0;
                    for (kx = 0; kx < kdim; kx = kx + 1)
                        acc = acc + (matA[ii][kx] * matB[kx][jj]);
                    matC_expect[ii][jj] = acc;
                    c_seen[ii][jj]      = 1'b0;
                end
        end
    endtask

    task clear_mats;
        integer ii, jj;
        begin
            for (ii = 0; ii < MAXDIM; ii = ii + 1)
                for (jj = 0; jj < MAXDIM; jj = jj + 1) begin
                    matA[ii][jj]        = 0;
                    matB[ii][jj]        = 0;
                    matC_expect[ii][jj] = 0;
                    c_seen[ii][jj]      = 1'b0;
                end
        end
    endtask

    //--------------------------------------------------------
    // Capture streamed results and check each against the model.
    //--------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n && c_valid) begin
            checks = checks + 1;
            c_seen[c_row][c_col] = 1'b1;

            if ($signed(c_data) !== matC_expect[c_row][c_col]) begin
                errors = errors + 1;
                $display("    FAIL C[%0d][%0d] = %0d, expected %0d",
                         c_row, c_col, $signed(c_data),
                         matC_expect[c_row][c_col]);
            end
        end
    end

    //--------------------------------------------------------
    task run_gemm;
        input [511:0]        name;
        input integer        m, n, kdim;
        input [1:0]          mode;
        input                isign;
        integer              guard, ii, jj, missing;
        begin
            compute_expected(m, n, kdim);

            dim_m     = m[DIM_WIDTH-1:0];
            dim_n     = n[DIM_WIDTH-1:0];
            dim_k     = kdim[DIM_WIDTH-1:0];
            lane_mode = mode;
            is_signed = isign;

            start = 1'b1;
            @(posedge clk);
            #1;
            start = 1'b0;

            guard = 0;
            while (!done && guard < 5000) begin
                @(posedge clk);
                #1;
                guard = guard + 1;
            end

            if (guard >= 5000) begin
                errors = errors + 1;
                $display("FAIL [%0s] TIMEOUT", name);
            end
            else begin
                // Every element must have been emitted exactly once.
                missing = 0;
                for (ii = 0; ii < m; ii = ii + 1)
                    for (jj = 0; jj < n; jj = jj + 1)
                        if (!c_seen[ii][jj]) missing = missing + 1;

                checks = checks + 1;
                if (missing != 0) begin
                    errors = errors + 1;
                    $display("FAIL [%0s] %0d of %0d elements never emitted",
                             name, missing, m*n);
                end
                else begin
                    $display("ok   [%0s] %0dx%0d . %0dx%0d -> %0d elements",
                             name, m, kdim, kdim, n, m*n);
                end
            end

            @(posedge clk);
            #1;
        end
    endtask

    //--------------------------------------------------------
    initial begin
        checks    = 0;
        errors    = 0;
        start     = 1'b0;
        is_signed = 1'b1;
        lane_mode = LANE_8;
        dim_m     = 0;
        dim_n     = 0;
        dim_k     = 0;
        clear_mats;

        $display("================================================");
        $display("MATRIX TILE TESTBENCH");
        $display("================================================");

        rst_n = 1'b0;
        @(posedge clk);
        #1;
        rst_n = 1'b1;
        @(posedge clk);
        #1;

        //----------------------------------------------------
        // Identity: A x I must return A.
        //----------------------------------------------------
        $display("-- identity --");
        clear_mats;
        for (i = 0; i < 4; i = i + 1) begin
            for (j = 0; j < 4; j = j + 1)
                matA[i][j] = (i * 4) + j + 1;    // 1..16
            matB[i][i] = 1;                      // identity
        end
        run_gemm("4x4 . identity == A", 4, 4, 4, LANE_8, 1'b1);

        //----------------------------------------------------
        // 2x2, from the test plan.
        //   [1 2] [5 6]   [19 22]
        //   [3 4] [7 8] = [43 50]
        //----------------------------------------------------
        $display("-- 2x2 --");
        clear_mats;
        matA[0][0]=1; matA[0][1]=2;
        matA[1][0]=3; matA[1][1]=4;
        matB[0][0]=5; matB[0][1]=6;
        matB[1][0]=7; matB[1][1]=8;
        run_gemm("2x2 multiply", 2, 2, 2, LANE_8, 1'b1);

        //----------------------------------------------------
        // 4x4 dense
        //----------------------------------------------------
        $display("-- 4x4 --");
        clear_mats;
        for (i = 0; i < 4; i = i + 1)
            for (j = 0; j < 4; j = j + 1) begin
                matA[i][j] = i + j + 1;
                matB[i][j] = (i * 2) - j;
            end
        run_gemm("4x4 dense", 4, 4, 4, LANE_8, 1'b1);

        //----------------------------------------------------
        // Non-square: (2x3) . (3x4) -> (2x4)
        //----------------------------------------------------
        $display("-- non-square --");
        clear_mats;
        for (i = 0; i < 2; i = i + 1)
            for (k = 0; k < 3; k = k + 1)
                matA[i][k] = i + k + 1;
        for (k = 0; k < 3; k = k + 1)
            for (j = 0; j < 4; j = j + 1)
                matB[k][j] = k - j;
        run_gemm("2x3 . 3x4 -> 2x4", 2, 4, 3, LANE_8, 1'b1);

        // Matrix-vector: (4x4) . (4x1)
        clear_mats;
        for (i = 0; i < 4; i = i + 1) begin
            for (k = 0; k < 4; k = k + 1)
                matA[i][k] = i + k;
            matB[i][0] = i + 1;
        end
        run_gemm("matrix-vector 4x4 . 4x1", 4, 1, 4, LANE_8, 1'b1);

        //----------------------------------------------------
        // TILE BOUNDARY CASES
        //
        // The k iterator advances by the lane count (8 at int8), so a K that
        // is NOT a multiple of 8 must still work - the operand supply zeroes
        // the lanes past dim_k so they contribute nothing.
        //----------------------------------------------------
        $display("-- tile boundaries (K not a multiple of lanes) --");

        // K = 1: a single element, 7 of 8 lanes unused.
        clear_mats;
        matA[0][0] = 6;
        matB[0][0] = 7;
        run_gemm("K=1 (6*7=42)", 1, 1, 1, LANE_8, 1'b1);

        // K = 7: one short of a full 8-lane chunk.
        clear_mats;
        for (k = 0; k < 7; k = k + 1) begin
            matA[0][k] = k + 1;      // 1..7
            matB[k][0] = 2;
        end
        run_gemm("K=7 (2*28=56), 1 lane unused", 1, 1, 7, LANE_8, 1'b1);

        // K = 8: exactly one full chunk.
        clear_mats;
        for (k = 0; k < 8; k = k + 1) begin
            matA[0][k] = k + 1;      // 1..8
            matB[k][0] = 1;
        end
        run_gemm("K=8 (exactly one chunk, =36)", 1, 1, 8, LANE_8, 1'b1);

        // K = 9: spills into a second chunk with 7 lanes unused.
        clear_mats;
        for (k = 0; k < 9; k = k + 1) begin
            matA[0][k] = 1;
            matB[k][0] = 1;
        end
        run_gemm("K=9 (spans 2 chunks, =9)", 1, 1, 9, LANE_8, 1'b1);

        // K = 12 with 2x2 output: partial second chunk, multiple elements.
        clear_mats;
        for (i = 0; i < 2; i = i + 1)
            for (k = 0; k < 12; k = k + 1)
                matA[i][k] = (k % 3) + 1;
        for (k = 0; k < 12; k = k + 1)
            for (j = 0; j < 2; j = j + 1)
                matB[k][j] = (k % 2) ? 2 : -1;
        run_gemm("K=12, 2x2 out, partial chunk", 2, 2, 12, LANE_8, 1'b1);

        //----------------------------------------------------
        // Negatives
        //----------------------------------------------------
        $display("-- negatives --");
        clear_mats;
        matA[0][0] = -2; matA[0][1] =  3;
        matA[1][0] =  4; matA[1][1] = -5;
        matB[0][0] =  1; matB[0][1] = -1;
        matB[1][0] = -2; matB[1][1] =  2;
        run_gemm("2x2 with negatives", 2, 2, 2, LANE_8, 1'b1);

        //----------------------------------------------------
        // Wider lanes: int16 (4 lanes) and int64 (1 lane).
        //----------------------------------------------------
        $display("-- lane modes --");

        clear_mats;
        for (i = 0; i < 2; i = i + 1)
            for (k = 0; k < 4; k = k + 1) begin
                matA[i][k] = (i + 1) * 100;      // needs > 8 bits
                matB[k][i] = k + 1;
            end
        run_gemm("int16 lanes, 2x4 . 4x2", 2, 2, 4, LANE_16, 1'b1);

        clear_mats;
        matA[0][0] = 1000; matA[0][1] = 2000;
        matB[0][0] = 3000; matB[1][0] = 4000;
        run_gemm("int64 lanes, 1x2 . 2x1", 1, 1, 2, LANE_64, 1'b1);

        //----------------------------------------------------
        // Empty dimensions must complete, not hang.
        //----------------------------------------------------
        $display("-- empty --");
        clear_mats;
        run_gemm("M=0 completes", 0, 4, 4, LANE_8, 1'b1);
        run_gemm("K=0 completes", 2, 2, 0, LANE_8, 1'b1);

        //----------------------------------------------------
        $display("================================================");
        $display("CHECKS: %0d   ERRORS: %0d", checks, errors);
        if (errors == 0)
            $display("RESULT: ALL MATRIX TILE TESTS PASSED");
        else
            $display("RESULT: MATRIX TILE TESTS FAILED");
        $display("================================================");
        $finish;
    end

endmodule
