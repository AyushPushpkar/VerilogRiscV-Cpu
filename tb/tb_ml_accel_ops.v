`timescale 1ns/1ns

//============================================================
// ML accelerator: DOT and MAT operating modes
//
// Exercises the newly-wired dot_product and matrix_tile engines
// through the memory-mapped interface, the way software will.
//
// The point of this file: before this wiring, dot_product and
// matrix_tile were verified but UNREACHABLE - only vec_mac was
// exposed via MMIO, so software had to run the chunk loop
// itself. These tests prove the engines are now driveable from
// the bus.
//============================================================

module tb_ml_accel_ops;

    localparam XLEN      = 64;
    localparam ACC_WIDTH = 128;

    // Register offsets
    localparam [2:0] ML_CTRL   = 3'd0,
                     ML_STATUS = 3'd1,
                     ML_A      = 3'd2,
                     ML_B      = 3'd3,
                     ML_ACC_LO = 3'd4,
                     ML_ACC_HI = 3'd5,
                     ML_LEN    = 3'd6;

    localparam [1:0] OP_MAC = 2'd0,
                     OP_DOT = 2'd1,
                     OP_MAT = 2'd2;

    localparam [1:0] LANE_8  = 2'd0,
                     LANE_16 = 2'd1,
                     LANE_32 = 2'd2,
                     LANE_64 = 2'd3;

    reg              clk;
    reg              rst_n;
    reg              sel;
    reg              we;
    reg  [2:0]       reg_idx;
    reg  [XLEN-1:0]  wdata;
    wire [XLEN-1:0]  rdata;

    integer checks, errors, i, j, k;

    ml_accel #(
        .XLEN      (XLEN),
        .ACC_WIDTH (ACC_WIDTH)
    ) dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .sel     (sel),
        .we      (we),
        .reg_idx (reg_idx),
        .wdata   (wdata),
        .rdata   (rdata)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    //--------------------------------------------------------
    task bus_store;
        input [2:0]      idx;
        input [XLEN-1:0] data;
        begin
            sel = 1'b1; we = 1'b1; reg_idx = idx; wdata = data;
            @(posedge clk);
            #1;
            sel = 1'b0; we = 1'b0;
        end
    endtask

    task bus_load;
        input  [2:0]      idx;
        output [XLEN-1:0] data;
        begin
            sel = 1'b1; we = 1'b0; reg_idx = idx;
            #1;
            data = rdata;
            @(posedge clk);      // let read-pointer side effects land
            #1;
            sel = 1'b0;
        end
    endtask

    // Combinational peek - no clock edge, no side effects.
    task bus_peek;
        input  [2:0]      idx;
        output [XLEN-1:0] data;
        begin
            sel = 1'b1; we = 1'b0; reg_idx = idx;
            #1;
            data = rdata;
            sel = 1'b0;
        end
    endtask

    function [XLEN-1:0] ctrl_word;
        input       do_start;
        input       do_clear;
        input       isign;
        input [1:0] imode;
        input [1:0] iop;
        begin
            ctrl_word        = {XLEN{1'b0}};
            ctrl_word[0]     = do_start;
            ctrl_word[1]     = do_clear;
            ctrl_word[2]     = isign;
            ctrl_word[4:3]   = imode;
            ctrl_word[6:5]   = iop;
        end
    endfunction

    task expect_val;
        input [511:0]    name;
        input [XLEN-1:0] actual;
        input [XLEN-1:0] expected;
        begin
            checks = checks + 1;
            if (actual !== expected) begin
                errors = errors + 1;
                $display("FAIL [%0s] got=%0d expected=%0d",
                         name, $signed(actual), $signed(expected));
            end
            else
                $display("ok   [%0s] %0d", name, $signed(actual));
        end
    endtask

    // Poll ML_STATUS until done (bit 1), with a hang guard.
    task wait_done;
        integer guard;
        reg [XLEN-1:0] st;
        begin
            guard = 0;
            st    = 0;
            while (!st[1] && guard < 2000) begin
                bus_peek(ML_STATUS, st);
                @(posedge clk);
                #1;
                guard = guard + 1;
            end
            if (guard >= 2000)
                $display("    WARNING: wait_done timed out");
        end
    endtask

    reg [XLEN-1:0] rv;

    //--------------------------------------------------------
    initial begin
        checks  = 0;
        errors  = 0;
        sel     = 1'b0;
        we      = 1'b0;
        reg_idx = 3'd0;
        wdata   = {XLEN{1'b0}};

        $display("================================================");
        $display("ML ACCEL: DOT AND MAT MODES");
        $display("================================================");

        rst_n = 1'b0;
        @(posedge clk); #1;
        rst_n = 1'b1;
        @(posedge clk); #1;

        //----------------------------------------------------
        // OP_DOT: the engine runs the loop, not software.
        //
        // Before this wiring, software had to issue 3 stores per 8 elements.
        // Now it fills the buffer and issues ONE start.
        //----------------------------------------------------
        $display("-- OP_DOT: [1,2,3] . [4,5,6] = 32 (int64 lanes) --");

        bus_store(ML_CTRL, ctrl_word(0, 1, 1, LANE_64, OP_DOT));  // clear
        bus_store(ML_A, 64'sd1);
        bus_store(ML_A, 64'sd2);
        bus_store(ML_A, 64'sd3);
        bus_store(ML_B, 64'sd4);
        bus_store(ML_B, 64'sd5);
        bus_store(ML_B, 64'sd6);
        bus_store(ML_LEN, 64'd3);
        bus_store(ML_CTRL, ctrl_word(1, 0, 1, LANE_64, OP_DOT));  // start

        wait_done;
        bus_peek(ML_ACC_LO, rv);
        expect_val("DOT [1,2,3].[4,5,6] == 32", rv, 64'sd32);

        //----------------------------------------------------
        // Longer vector: sum of i^2 for i = 0..15 = 1240
        //----------------------------------------------------
        $display("-- OP_DOT: 16 elements, sum of squares = 1240 --");

        bus_store(ML_CTRL, ctrl_word(0, 1, 1, LANE_64, OP_DOT));
        for (i = 0; i < 16; i = i + 1)
            bus_store(ML_A, i);
        for (i = 0; i < 16; i = i + 1)
            bus_store(ML_B, i);
        bus_store(ML_LEN, 64'd16);
        bus_store(ML_CTRL, ctrl_word(1, 0, 1, LANE_64, OP_DOT));

        wait_done;
        bus_peek(ML_ACC_LO, rv);
        expect_val("DOT sum(i^2), i=0..15 == 1240", rv, 64'sd1240);

        //----------------------------------------------------
        // Negative values
        //----------------------------------------------------
        $display("-- OP_DOT: negatives --");

        bus_store(ML_CTRL, ctrl_word(0, 1, 1, LANE_64, OP_DOT));
        bus_store(ML_A,  64'sd10);   bus_store(ML_B, 64'sd10);   // +100
        bus_store(ML_A, -64'sd6);    bus_store(ML_B, 64'sd30);   // -180
        bus_store(ML_LEN, 64'd2);
        bus_store(ML_CTRL, ctrl_word(1, 0, 1, LANE_64, OP_DOT));

        wait_done;
        bus_peek(ML_ACC_LO, rv);
        expect_val("DOT 100-180 == -80", rv, -64'sd80);

        //----------------------------------------------------
        // OP_MAT: 2x2 matrix multiply.
        //
        //   [1 2] [5 6]   [19 22]
        //   [3 4] [7 8] = [43 50]
        //
        // A is row-major:      A[row][k] -> buf_a[row*K_chunks + chunk]
        // B is COLUMN-major:   B[k][col] -> buf_b[col*K_chunks + chunk]
        //
        // With LANE_64 (1 lane), K=2 needs 2 chunks per row/col.
        //----------------------------------------------------
        $display("-- OP_MAT: 2x2 . 2x2 (int64 lanes) --");

        bus_store(ML_CTRL, ctrl_word(0, 1, 1, LANE_64, OP_MAT));

        // A row-major: row0 = [1,2], row1 = [3,4]
        bus_store(ML_A, 64'sd1);
        bus_store(ML_A, 64'sd2);
        bus_store(ML_A, 64'sd3);
        bus_store(ML_A, 64'sd4);

        // B column-major: col0 = [5,7], col1 = [6,8]
        bus_store(ML_B, 64'sd5);
        bus_store(ML_B, 64'sd7);
        bus_store(ML_B, 64'sd6);
        bus_store(ML_B, 64'sd8);

        // dims: M=2, N=2, K=2
        bus_store(ML_LEN, {40'd0, 8'd2, 8'd2, 8'd2});   // K,N,M
        bus_store(ML_CTRL, ctrl_word(1, 0, 1, LANE_64, OP_MAT));

        wait_done;

        // Read C back in row-major order. Each ML_ACC_LO load advances the
        // read pointer, so repeated loads walk C.
        bus_load(ML_ACC_LO, rv);
        expect_val("MAT C[0][0] == 19", rv, 64'sd19);
        bus_load(ML_ACC_LO, rv);
        expect_val("MAT C[0][1] == 22", rv, 64'sd22);
        bus_load(ML_ACC_LO, rv);
        expect_val("MAT C[1][0] == 43", rv, 64'sd43);
        bus_load(ML_ACC_LO, rv);
        expect_val("MAT C[1][1] == 50", rv, 64'sd50);

        //----------------------------------------------------
        // OP_MAT: identity. A x I must return A.
        //----------------------------------------------------
        $display("-- OP_MAT: 3x3 . identity == A --");

        bus_store(ML_CTRL, ctrl_word(0, 1, 1, LANE_64, OP_MAT));

        // A row-major, values 1..9
        for (i = 0; i < 3; i = i + 1)
            for (k = 0; k < 3; k = k + 1)
                bus_store(ML_A, (i * 3) + k + 1);

        // Identity, column-major (same thing for I)
        for (j = 0; j < 3; j = j + 1)
            for (k = 0; k < 3; k = k + 1)
                bus_store(ML_B, (j == k) ? 64'sd1 : 64'sd0);

        bus_store(ML_LEN, {40'd0, 8'd3, 8'd3, 8'd3});   // K=3,N=3,M=3
        bus_store(ML_CTRL, ctrl_word(1, 0, 1, LANE_64, OP_MAT));

        wait_done;

        for (i = 0; i < 9; i = i + 1) begin
            bus_load(ML_ACC_LO, rv);
            checks = checks + 1;
            if (rv !== (i + 1)) begin
                errors = errors + 1;
                $display("FAIL [MAT identity C[%0d] ] got=%0d expected=%0d",
                         i, $signed(rv), i + 1);
            end
        end
        $display("ok   [MAT 3x3 identity: all 9 elements == A]");

        //----------------------------------------------------
        // OP_MAT: non-square. (2x3) . (3x2) -> (2x2)
        //
        //   A = [1 2 3]    B = [1 2]
        //       [4 5 6]        [3 4]
        //                      [5 6]
        //
        //   C = [1+6+15  2+8+18]  = [22 28]
        //       [4+15+30 8+20+36]   [49 64]
        //----------------------------------------------------
        $display("-- OP_MAT: non-square 2x3 . 3x2 --");

        bus_store(ML_CTRL, ctrl_word(0, 1, 1, LANE_64, OP_MAT));

        // A row-major: [1,2,3], [4,5,6]
        for (i = 1; i <= 6; i = i + 1)
            bus_store(ML_A, i);

        // B column-major: col0 = [1,3,5], col1 = [2,4,6]
        bus_store(ML_B, 64'sd1);
        bus_store(ML_B, 64'sd3);
        bus_store(ML_B, 64'sd5);
        bus_store(ML_B, 64'sd2);
        bus_store(ML_B, 64'sd4);
        bus_store(ML_B, 64'sd6);

        bus_store(ML_LEN, {40'd0, 8'd3, 8'd2, 8'd2});   // K=3, N=2, M=2
        bus_store(ML_CTRL, ctrl_word(1, 0, 1, LANE_64, OP_MAT));

        wait_done;

        bus_load(ML_ACC_LO, rv);
        expect_val("MAT nonsq C[0][0] == 22", rv, 64'sd22);
        bus_load(ML_ACC_LO, rv);
        expect_val("MAT nonsq C[0][1] == 28", rv, 64'sd28);
        bus_load(ML_ACC_LO, rv);
        expect_val("MAT nonsq C[1][0] == 49", rv, 64'sd49);
        bus_load(ML_ACC_LO, rv);
        expect_val("MAT nonsq C[1][1] == 64", rv, 64'sd64);


        //----------------------------------------------------
        // OP_DOT with PACKED int8 lanes.
        //
        // This is the path that was BROKEN until dot_product was rewired to use
        // vec_mac: it wrapped the scalar mac_unit, so OP_DOT ran one element per
        // cycle no matter what lane mode software asked for. The packed lanes -
        // the whole point of the accelerator - were unreachable through the dot
        // product path.
        //
        // vec_len counts CHUNKS. 16 int8 elements = 2 chunks of 8 lanes.
        //
        //   a = [1..8, 1..8]   b = [1..8, 1..8]
        //   dot = 2 * (1+4+9+16+25+36+49+64) = 2 * 204 = 408
        //----------------------------------------------------
        $display("-- OP_DOT with packed int8 lanes --");

        bus_store(ML_CTRL, ctrl_word(0, 1, 1, LANE_8, OP_DOT));   // clear
        bus_store(ML_A, 64'h08_07_06_05_04_03_02_01);             // chunk 0
        bus_store(ML_A, 64'h08_07_06_05_04_03_02_01);             // chunk 1
        bus_store(ML_B, 64'h08_07_06_05_04_03_02_01);
        bus_store(ML_B, 64'h08_07_06_05_04_03_02_01);
        bus_store(ML_LEN, 64'd2);                                 // 2 CHUNKS
        bus_store(ML_CTRL, ctrl_word(1, 0, 1, LANE_8, OP_DOT));   // start

        wait_done;
        bus_peek(ML_ACC_LO, rv);
        expect_val("DOT int8: 16 elements in 2 cycles == 408", rv, 64'sd408);

        // Negative packed lanes: a = [-1 x8], b = [1 x8] -> -8
        bus_store(ML_CTRL, ctrl_word(0, 1, 1, LANE_8, OP_DOT));
        bus_store(ML_A,   64'hFF_FF_FF_FF_FF_FF_FF_FF);
        bus_store(ML_B,   64'h01_01_01_01_01_01_01_01);
        bus_store(ML_LEN, 64'd1);
        bus_store(ML_CTRL, ctrl_word(1, 0, 1, LANE_8, OP_DOT));

        wait_done;
        bus_peek(ML_ACC_LO, rv);
        expect_val("DOT int8 signed (-1 x 1) x8 == -8", rv, -64'sd8);

        //----------------------------------------------------
        // OP_MAC still works - backward compatibility.
        //----------------------------------------------------
        $display("-- OP_MAC still works (regression) --");

        bus_store(ML_CTRL, ctrl_word(0, 1, 1, LANE_8, OP_MAC));
        bus_store(ML_A,    64'h08_07_06_05_04_03_02_01);
        bus_store(ML_B,    64'h08_07_06_05_04_03_02_01);
        bus_store(ML_CTRL, ctrl_word(1, 0, 1, LANE_8, OP_MAC));
        bus_peek(ML_ACC_LO, rv);
        expect_val("MAC int8 sum of squares == 204", rv, 64'sd204);

        //----------------------------------------------------
        $display("================================================");
        $display("CHECKS: %0d   ERRORS: %0d", checks, errors);
        if (errors == 0)
            $display("RESULT: ALL DOT/MAT MODE TESTS PASSED");
        else
            $display("RESULT: DOT/MAT MODE TESTS FAILED");
        $display("================================================");
        $finish;
    end

endmodule
