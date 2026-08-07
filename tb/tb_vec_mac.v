`timescale 1ns/1ns

//============================================================
// Packed vector MAC testbench
// Steps 4-5 of the ML RTL order: packed lanes + reduction.
//
// The headline check: a 64-element int8 dot product computed
// in 8 packed cycles must equal the same dot product computed
// scalar-style, element by element.
//============================================================

module tb_vec_mac;

    localparam DATA_WIDTH = 64;
    localparam ACC_WIDTH  = 128;

    localparam [1:0] LANE_8  = 2'd0,
                     LANE_16 = 2'd1,
                     LANE_32 = 2'd2,
                     LANE_64 = 2'd3;

    reg                    clk;
    reg                    rst_n;
    reg                    clear;
    reg                    en;
    reg                    is_signed;
    reg  [1:0]             lane_mode;
    reg  [DATA_WIDTH-1:0]  a;
    reg  [DATA_WIDTH-1:0]  b;
    wire [ACC_WIDTH-1:0]   acc;
    wire [ACC_WIDTH-1:0]   lane_sum;

    integer checks;
    integer errors;
    integer i;

    vec_mac #(
        .DATA_WIDTH (DATA_WIDTH),
        .ACC_WIDTH  (ACC_WIDTH)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .clear     (clear),
        .en        (en),
        .is_signed (is_signed),
        .lane_mode (lane_mode),
        .a         (a),
        .b         (b),
        .acc       (acc),
        .lane_sum  (lane_sum)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    //--------------------------------------------------------
    // Drive one packed accumulate cycle.
    //--------------------------------------------------------
    task do_vec;
        input [DATA_WIDTH-1:0] ia;
        input [DATA_WIDTH-1:0] ib;
        input                  isign;
        input [1:0]            imode;
        begin
            a         = ia;
            b         = ib;
            is_signed = isign;
            lane_mode = imode;
            en        = 1'b1;
            @(posedge clk);
            #1;
            en        = 1'b0;
        end
    endtask

    task do_clear;
        begin
            clear = 1'b1;
            @(posedge clk);
            #1;
            clear = 1'b0;
        end
    endtask

    task expect_acc;
        input [511:0]         name;    // 64 chars; long test labels overflow 32
        input [ACC_WIDTH-1:0] expected;
        begin
            checks = checks + 1;
            if (acc !== expected) begin
                errors = errors + 1;
                $display("FAIL [%0s] acc=%0d expected=%0d",
                         name, $signed(acc), $signed(expected));
            end
            else begin
                $display("ok   [%0s] acc=%0d", name, $signed(acc));
            end
        end
    endtask

    //--------------------------------------------------------
    initial begin
        checks    = 0;
        errors    = 0;
        clear     = 1'b0;
        en        = 1'b0;
        is_signed = 1'b1;
        lane_mode = LANE_8;
        a         = {DATA_WIDTH{1'b0}};
        b         = {DATA_WIDTH{1'b0}};

        $display("================================================");
        $display("PACKED VECTOR MAC TESTBENCH");
        $display("================================================");

        rst_n = 1'b0;
        @(posedge clk);
        #1;
        rst_n = 1'b1;
        expect_acc("reset clears acc", 128'sd0);

        //----------------------------------------------------
        // int8 lanes: 8 MACs in ONE cycle
        //----------------------------------------------------
        $display("-- int8 lanes (8 per cycle) --");

        // a = [1,2,3,4,5,6,7,8], b = [1,1,1,1,1,1,1,1]
        // dot = 1+2+3+4+5+6+7+8 = 36
        // Lane 0 is the LOW byte, so byte order is reversed in the literal.
        do_clear;
        do_vec(64'h08_07_06_05_04_03_02_01,
               64'h01_01_01_01_01_01_01_01, 1'b1, LANE_8);
        expect_acc("int8 [1..8].[1x8] == 36", 128'sd36);

        // a = [1..8], b = [1..8]  -> sum of squares = 1+4+9+16+25+36+49+64 = 204
        do_clear;
        do_vec(64'h08_07_06_05_04_03_02_01,
               64'h08_07_06_05_04_03_02_01, 1'b1, LANE_8);
        expect_acc("int8 sum of squares == 204", 128'sd204);

        // Negative lanes: a = [-1,-1,...], b = [1,1,...] -> -8
        do_clear;
        do_vec(64'hFF_FF_FF_FF_FF_FF_FF_FF,
               64'h01_01_01_01_01_01_01_01, 1'b1, LANE_8);
        expect_acc("int8 signed -1 x 1 x8 == -8", -128'sd8);

        // Same bits, UNSIGNED: 0xFF = 255, so 255*1 * 8 = 2040
        do_clear;
        do_vec(64'hFF_FF_FF_FF_FF_FF_FF_FF,
               64'h01_01_01_01_01_01_01_01, 1'b0, LANE_8);
        expect_acc("int8 unsigned 255 x 1 x8 == 2040", 128'sd2040);

        // Max magnitude signed: -128 * -128 = +16384, times 8 lanes = 131072
        do_clear;
        do_vec(64'h80_80_80_80_80_80_80_80,
               64'h80_80_80_80_80_80_80_80, 1'b1, LANE_8);
        expect_acc("int8 (-128 * -128) x8 == 131072", 128'sd131072);

        //----------------------------------------------------
        // int16 lanes: 4 MACs per cycle
        //----------------------------------------------------
        $display("-- int16 lanes (4 per cycle) --");

        // a = [1,2,3,4], b = [10,20,30,40] -> 10+40+90+160 = 300
        do_clear;
        do_vec(64'h0004_0003_0002_0001,
               64'h0028_001E_0014_000A, 1'b1, LANE_16);
        expect_acc("int16 [1,2,3,4].[10,20,30,40] == 300", 128'sd300);

        // Negative: [-2,-2,-2,-2] . [3,3,3,3] = -24
        do_clear;
        do_vec(64'hFFFE_FFFE_FFFE_FFFE,
               64'h0003_0003_0003_0003, 1'b1, LANE_16);
        expect_acc("int16 (-2 * 3) x4 == -24", -128'sd24);

        //----------------------------------------------------
        // int32 lanes: 2 MACs per cycle
        //----------------------------------------------------
        $display("-- int32 lanes (2 per cycle) --");

        // [1000, 2000] . [3000, 4000] = 3,000,000 + 8,000,000 = 11,000,000
        do_clear;
        do_vec(64'h000007D0_000003E8,     // [2000, 1000]
               64'h00000FA0_00000BB8,     // [4000, 3000]
               1'b1, LANE_32);
        expect_acc("int32 [1000,2000].[3000,4000] == 11000000", 128'sd11000000);

        //----------------------------------------------------
        // int64: single lane, must match mac_unit behavior
        //----------------------------------------------------
        $display("-- int64 (1 per cycle) --");

        do_clear;
        do_vec(64'sd3, 64'sd4, 1'b1, LANE_64);
        expect_acc("int64 3*4 == 12", 128'sd12);

        // Wide product must not truncate: 2^40 * 2^40 = 2^80
        do_clear;
        do_vec(64'h0000010000000000, 64'h0000010000000000, 1'b1, LANE_64);
        expect_acc("int64 2^40*2^40 == 2^80",
                   128'h00000000_00010000_00000000_00000000);

        //----------------------------------------------------
        // Control behavior
        //----------------------------------------------------
        $display("-- control --");

        // en=0 must hold the accumulator
        do_clear;
        do_vec(64'h01_01_01_01_01_01_01_01,
               64'h01_01_01_01_01_01_01_01, 1'b1, LANE_8);   // acc = 8
        en = 1'b0;
        a  = 64'hFF_FF_FF_FF_FF_FF_FF_FF;   // garbage, must be ignored
        b  = 64'hFF_FF_FF_FF_FF_FF_FF_FF;
        @(posedge clk);
        #1;
        expect_acc("en=0 holds acc", 128'sd8);

        // clear zeroes it
        do_clear;
        expect_acc("clear zeroes acc", 128'sd0);

        //----------------------------------------------------
        // Multi-cycle accumulation across packed vectors
        //----------------------------------------------------
        $display("-- accumulate across cycles --");

        do_clear;
        // Three cycles of [1..8].[1,1,1,1,1,1,1,1] = 36 each -> 108
        for (i = 0; i < 3; i = i + 1) begin
            do_vec(64'h08_07_06_05_04_03_02_01,
                   64'h01_01_01_01_01_01_01_01, 1'b1, LANE_8);
        end
        expect_acc("3 x 36 accumulated == 108", 128'sd108);

        //----------------------------------------------------
        // THE HEADLINE TEST
        //
        // 64-element int8 dot product, done two ways:
        //   scalar : 64 cycles of 1 MAC   (LANE_64, one element at a time)
        //   packed : 8 cycles of 8 MACs   (LANE_8)
        // Both must produce the identical answer.
        //----------------------------------------------------
        $display("-- packed vs scalar equivalence (64 int8 elements) --");
        begin : equivalence
            reg [7:0]           va [0:63];
            reg [7:0]           vb [0:63];
            reg [ACC_WIDTH-1:0] scalar_result;
            reg [DATA_WIDTH-1:0] pa, pb;
            integer j, k;

            // Build two 64-element int8 vectors with a mix of signs.
            for (j = 0; j < 64; j = j + 1) begin
                va[j] = j - 32;          // -32 .. 31
                vb[j] = (j % 7) - 3;     // -3 .. 3, repeating
            end

            // --- scalar: 64 cycles, one element per cycle, LANE_64 ---
            do_clear;
            for (j = 0; j < 64; j = j + 1) begin
                // Sign-extend each int8 element into the full 64-bit lane.
                do_vec({{56{va[j][7]}}, va[j]},
                       {{56{vb[j][7]}}, vb[j]}, 1'b1, LANE_64);
            end
            scalar_result = acc;
            $display("     scalar (64 cycles): %0d", $signed(scalar_result));

            // --- packed: 8 cycles, 8 elements per cycle, LANE_8 ---
            do_clear;
            for (j = 0; j < 8; j = j + 1) begin
                // Pack 8 consecutive int8s into one 64-bit word.
                // Lane k occupies byte k, so element (j*8+k) -> byte k.
                for (k = 0; k < 8; k = k + 1) begin
                    pa[k*8 +: 8] = va[j*8 + k];
                    pb[k*8 +: 8] = vb[j*8 + k];
                end
                do_vec(pa, pb, 1'b1, LANE_8);
            end
            $display("     packed (8 cycles):  %0d", $signed(acc));

            checks = checks + 1;
            if (acc !== scalar_result) begin
                errors = errors + 1;
                $display("FAIL [packed == scalar] packed=%0d scalar=%0d",
                         $signed(acc), $signed(scalar_result));
            end
            else begin
                $display("ok   [packed == scalar] both %0d, 8x fewer cycles",
                         $signed(acc));
            end
        end

        //----------------------------------------------------
        $display("================================================");
        $display("CHECKS: %0d   ERRORS: %0d", checks, errors);
        if (errors == 0)
            $display("RESULT: ALL VECTOR MAC TESTS PASSED");
        else
            $display("RESULT: VECTOR MAC TESTS FAILED");
        $display("================================================");
        $finish;
    end

endmodule
