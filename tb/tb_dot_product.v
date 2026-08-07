`timescale 1ns/1ns

//============================================================
// Dot-product unit testbench
// Step 3 of the ML RTL order: dot-product control around MAC.
//
// Models the operand source as two memories indexed by the
// DUT's `idx` output, and checks results against a software
// golden model computed over the same vectors.
//============================================================

module tb_dot_product;

    localparam OP_WIDTH  = 64;
    localparam ACC_WIDTH = 128;
    localparam LEN_WIDTH = 16;
    localparam MAXLEN    = 64;

    reg                    clk;
    reg                    rst_n;
    reg                    start;
    reg                    is_signed;
    reg  [1:0]             lane_mode;
    reg                    accumulate;
    reg  [LEN_WIDTH-1:0]   vec_len;

    wire [LEN_WIDTH-1:0]   idx;
    wire [OP_WIDTH-1:0]    a_data;
    wire [OP_WIDTH-1:0]    b_data;

    wire                   busy;
    wire                   done;
    wire [ACC_WIDTH-1:0]   result;

    integer checks;
    integer errors;
    integer i;

    // Operand storage. The DUT streams `idx`; we present the element.
    reg [OP_WIDTH-1:0] vec_a [0:MAXLEN-1];
    reg [OP_WIDTH-1:0] vec_b [0:MAXLEN-1];

    assign a_data = vec_a[idx];
    assign b_data = vec_b[idx];

    dot_product #(
        .OP_WIDTH  (OP_WIDTH),
        .ACC_WIDTH (ACC_WIDTH),
        .LEN_WIDTH (LEN_WIDTH)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (start),
        .is_signed (is_signed),
        .lane_mode  (lane_mode),
        .accumulate (accumulate),
        .vec_len    (vec_len),
        .idx       (idx),
        .a_data    (a_data),
        .b_data    (b_data),
        .busy      (busy),
        .done      (done),
        .result    (result)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    //--------------------------------------------------------
    // Software golden model over the loaded vectors
    //--------------------------------------------------------
    function [ACC_WIDTH-1:0] dot_ref;
        input [LEN_WIDTH-1:0] len;
        input                 isign;
        reg   [ACC_WIDTH-1:0] acc;
        integer               k;
        begin
            acc = {ACC_WIDTH{1'b0}};
            for (k = 0; k < len; k = k + 1) begin
                if (isign)
                    acc = $signed(acc) + ($signed(vec_a[k]) * $signed(vec_b[k]));
                else
                    acc = acc + (vec_a[k] * vec_b[k]);
            end
            dot_ref = acc;
        end
    endfunction

    //--------------------------------------------------------
    // Run one dot product and check against the golden model.
    //--------------------------------------------------------
    task run_dot;
        input [255:0]         name;
        input [LEN_WIDTH-1:0] len;
        input                 isign;
        reg   [ACC_WIDTH-1:0] expected;
        integer               guard;
        begin
            expected = dot_ref(len, isign);

            // Kick off
            vec_len   = len;
            is_signed = isign;
            start     = 1'b1;
            @(posedge clk);
            #1;
            start     = 1'b0;

            // Wait for done (with a hang guard)
            guard = 0;
            while (!done && guard < 1000) begin
                @(posedge clk);
                #1;
                guard = guard + 1;
            end

            checks = checks + 1;
            if (guard >= 1000) begin
                errors = errors + 1;
                $display("FAIL [%0s] TIMEOUT - done never asserted", name);
            end
            else if (result !== expected) begin
                errors = errors + 1;
                $display("FAIL [%0s] len=%0d result=%0d expected=%0d",
                         name, len, $signed(result), $signed(expected));
            end
            else begin
                $display("ok   [%0s] len=%0d result=%0d",
                         name, len, $signed(result));
            end

            // Settle back to idle before the next test.
            @(posedge clk);
            #1;
        end
    endtask

    task clear_vecs;
        integer k;
        begin
            for (k = 0; k < MAXLEN; k = k + 1) begin
                vec_a[k] = {OP_WIDTH{1'b0}};
                vec_b[k] = {OP_WIDTH{1'b0}};
            end
        end
    endtask

    //--------------------------------------------------------
    initial begin
        checks    = 0;
        errors    = 0;
        start     = 1'b0;
        is_signed = 1'b1;
        // These tests use one 64-bit value per buffer entry, which is LANE_64.
        // dot_product now supports packed lanes; LANE_8 coverage lives in
        // tb_ml_accel_ops.v, driven through the real MMIO path.
        lane_mode  = 2'd3;
        accumulate = 1'b0;      // each run starts from zero, as before
        vec_len    = {LEN_WIDTH{1'b0}};
        clear_vecs;

        $display("================================================");
        $display("DOT PRODUCT TESTBENCH");
        $display("================================================");

        rst_n = 1'b0;
        @(posedge clk);
        #1;
        rst_n = 1'b1;
        @(posedge clk);
        #1;

        //----------------------------------------------------
        // Golden vectors from docs/ML_TEST_PLAN.md
        //----------------------------------------------------
        $display("-- test plan vectors --");

        // [1,2,3] . [4,5,6] = 32
        clear_vecs;
        vec_a[0] = 64'sd1; vec_a[1] = 64'sd2; vec_a[2] = 64'sd3;
        vec_b[0] = 64'sd4; vec_b[1] = 64'sd5; vec_b[2] = 64'sd6;
        run_dot("[1,2,3].[4,5,6] == 32", 16'd3, 1'b1);

        // [0,0,0] . [7,8,9] = 0
        clear_vecs;
        vec_b[0] = 64'sd7; vec_b[1] = 64'sd8; vec_b[2] = 64'sd9;
        run_dot("[0,0,0].[7,8,9] == 0", 16'd3, 1'b1);

        //----------------------------------------------------
        // Edge cases from the test plan
        //----------------------------------------------------
        $display("-- edge cases --");

        // Empty vector: must complete, result 0.
        clear_vecs;
        run_dot("len=0 (empty)", 16'd0, 1'b1);

        // Length 1: degenerates to a single MAC.
        clear_vecs;
        vec_a[0] = 64'sd6;
        vec_b[0] = 64'sd7;
        run_dot("len=1 (6*7=42)", 16'd1, 1'b1);

        // Odd length.
        clear_vecs;
        for (i = 0; i < 5; i = i + 1) begin
            vec_a[i] = i + 1;      // [1,2,3,4,5]
            vec_b[i] = 64'sd2;
        end
        run_dot("len=5 odd (2*15=30)", 16'd5, 1'b1);

        // Negative values, sum crosses zero.
        clear_vecs;
        vec_a[0] =  64'sd10; vec_b[0] = 64'sd10;   // +100
        vec_a[1] = -64'sd6;  vec_b[1] = 64'sd30;   // -180
        vec_a[2] =  64'sd0;  vec_b[2] = 64'sd99;   //    0
        run_dot("negatives (100-180 == -80)", 16'd3, 1'b1);

        // All negative * negative = positive.
        clear_vecs;
        vec_a[0] = -64'sd3; vec_b[0] = -64'sd4;    // +12
        vec_a[1] = -64'sd5; vec_b[1] = -64'sd6;    // +30
        run_dot("neg*neg (12+30 == 42)", 16'd2, 1'b1);

        //----------------------------------------------------
        // Widened accumulator: products must not truncate,
        // and the SUM must not truncate either.
        //----------------------------------------------------
        $display("-- widened accumulator --");

        clear_vecs;
        // Four copies of 2^40 * 2^40 = 2^80, summing to 2^82.
        for (i = 0; i < 4; i = i + 1) begin
            vec_a[i] = 64'h0000010000000000;
            vec_b[i] = 64'h0000010000000000;
        end
        run_dot("4 * 2^80 == 2^82", 16'd4, 1'b1);

        //----------------------------------------------------
        // Unsigned mode
        //----------------------------------------------------
        $display("-- unsigned --");

        clear_vecs;
        vec_a[0] = {OP_WIDTH{1'b1}};   // 2^64-1
        vec_b[0] = 64'd2;
        run_dot("unsigned (2^64-1)*2", 16'd1, 1'b0);

        // Same bits, signed: -1 * 2 = -2.
        run_dot("signed -1*2 == -2", 16'd1, 1'b1);

        //----------------------------------------------------
        // Longer vector
        //----------------------------------------------------
        $display("-- longer vector --");

        clear_vecs;
        for (i = 0; i < 32; i = i + 1) begin
            vec_a[i] = i;
            vec_b[i] = i;             // sum of i^2, i=0..31 = 10416
        end
        run_dot("len=32 sum(i^2) == 10416", 16'd32, 1'b1);

        //----------------------------------------------------
        // Back-to-back: accumulator must be cleared on restart,
        // not carry residue from the previous run.
        //----------------------------------------------------
        $display("-- back to back --");

        clear_vecs;
        vec_a[0] = 64'sd100; vec_b[0] = 64'sd100;   // 10000
        run_dot("first run (100*100)", 16'd1, 1'b1);

        clear_vecs;
        vec_a[0] = 64'sd2; vec_b[0] = 64'sd3;       // must be 6, not 10006
        run_dot("second run clears acc (2*3==6)", 16'd1, 1'b1);

        //----------------------------------------------------
        // SOFTWARE TILING: accumulate across runs.
        //
        // A vector too big for the buffer is run as several tiles. The first
        // starts from zero; the rest accumulate. The partial sums must ADD.
        //
        //   tile 0: [1,2] . [10,10]  =  30
        //   tile 1: [3,4] . [10,10]  =  70
        //                     total  = 100
        //----------------------------------------------------
        $display("-- software tiling (accumulate across runs) --");

        clear_vecs;
        vec_a[0] = 64'sd1; vec_a[1] = 64'sd2;
        vec_b[0] = 64'sd10; vec_b[1] = 64'sd10;
        accumulate = 1'b0;                       // first tile: start from zero
        run_dot("tile 0 (=30)", 16'd2, 1'b1);

        clear_vecs;
        vec_a[0] = 64'sd3; vec_a[1] = 64'sd4;
        vec_b[0] = 64'sd10; vec_b[1] = 64'sd10;
        accumulate = 1'b1;                       // second tile: ADD to it
        // run_dot checks against dot_ref, which only knows this tile, so check
        // the accumulated total by hand instead.
        vec_len   = 16'd2;
        is_signed = 1'b1;
        start     = 1'b1;
        @(posedge clk); #1;
        start     = 1'b0;
        while (!done) begin @(posedge clk); #1; end

        checks = checks + 1;
        if ($signed(result) !== 128'sd100) begin
            errors = errors + 1;
            $display("FAIL [tiling: 30 + 70 == 100] got %0d", $signed(result));
        end
        else
            $display("ok   [tiling: 30 + 70 == 100] %0d", $signed(result));

        accumulate = 1'b0;   // restore

        //----------------------------------------------------
        $display("================================================");
        $display("CHECKS: %0d   ERRORS: %0d", checks, errors);
        if (errors == 0)
            $display("RESULT: ALL DOT PRODUCT TESTS PASSED");
        else
            $display("RESULT: DOT PRODUCT TESTS FAILED");
        $display("================================================");
        $finish;
    end

endmodule
