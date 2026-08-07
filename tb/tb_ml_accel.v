`timescale 1ns/1ns

//============================================================
// ML accelerator MMIO wrapper testbench
//
// Drives ml_accel exactly as the CPU will: stores to control
// and operand registers, loads from status and accumulator.
// This is the software contract, exercised directly.
//============================================================

module tb_ml_accel;

    localparam XLEN      = 64;
    localparam ACC_WIDTH = 128;

    // Register offsets
    localparam [2:0] ML_CTRL   = 3'd0,
                     ML_STATUS = 3'd1,
                     ML_A      = 3'd2,
                     ML_B      = 3'd3,
                     ML_ACC_LO = 3'd4,
                     ML_ACC_HI = 3'd5;

    // Lane modes
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

    integer checks;
    integer errors;
    integer i;

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
    // Bus transactions - these mimic CPU store / load
    //--------------------------------------------------------
    task bus_store;
        input [2:0]      idx;
        input [XLEN-1:0] data;
        begin
            sel     = 1'b1;
            we      = 1'b1;
            reg_idx = idx;
            wdata   = data;
            @(posedge clk);
            #1;
            sel     = 1'b0;
            we      = 1'b0;
        end
    endtask

    // Combinational read - no clock edge needed, like the CPU's async load.
    task bus_load;
        input  [2:0]      idx;
        output [XLEN-1:0] data;
        begin
            sel     = 1'b1;
            we      = 1'b0;
            reg_idx = idx;
            #1;
            data    = rdata;
            sel     = 1'b0;
        end
    endtask

    // Build a ML_CTRL word.
    function [XLEN-1:0] ctrl_word;
        input       do_start;
        input       do_clear;
        input       isign;
        input [1:0] imode;
        begin
            ctrl_word          = {XLEN{1'b0}};
            ctrl_word[0]       = do_start;
            ctrl_word[1]       = do_clear;
            ctrl_word[2]       = isign;
            ctrl_word[4:3]     = imode;
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
            else begin
                $display("ok   [%0s] %0d", name, $signed(actual));
            end
        end
    endtask

    reg [XLEN-1:0] rv;   // read value

    //--------------------------------------------------------
    initial begin
        checks  = 0;
        errors  = 0;
        sel     = 1'b0;
        we      = 1'b0;
        reg_idx = 3'd0;
        wdata   = {XLEN{1'b0}};

        $display("================================================");
        $display("ML ACCELERATOR (MMIO) TESTBENCH");
        $display("================================================");

        rst_n = 1'b0;
        @(posedge clk);
        #1;
        rst_n = 1'b1;
        @(posedge clk);
        #1;

        bus_load(ML_ACC_LO, rv);
        expect_val("reset: acc == 0", rv, 64'd0);

        //----------------------------------------------------
        // Operand registers must read back what was written
        //----------------------------------------------------
        $display("-- register read/write --");

        bus_store(ML_A, 64'hDEADBEEF_12345678);
        bus_load (ML_A, rv);
        expect_val("ML_A readback", rv, 64'hDEADBEEF_12345678);

        bus_store(ML_B, 64'hCAFEBABE_87654321);
        bus_load (ML_B, rv);
        expect_val("ML_B readback", rv, 64'hCAFEBABE_87654321);

        //----------------------------------------------------
        // Single int64 MAC: 3 * 4 = 12
        //----------------------------------------------------
        $display("-- single MAC via MMIO (int64) --");

        bus_store(ML_CTRL, ctrl_word(0, 1, 1, LANE_64));   // clear
        bus_load (ML_ACC_LO, rv);
        expect_val("after clear, acc == 0", rv, 64'd0);

        bus_store(ML_A,    64'sd3);
        bus_store(ML_B,    64'sd4);
        bus_store(ML_CTRL, ctrl_word(1, 0, 1, LANE_64));   // start
        bus_load (ML_ACC_LO, rv);
        expect_val("3*4 via MMIO == 12", rv, 64'sd12);

        // Accumulate again: +5*6 = 42
        bus_store(ML_A,    64'sd5);
        bus_store(ML_B,    64'sd6);
        bus_store(ML_CTRL, ctrl_word(1, 0, 1, LANE_64));
        bus_load (ML_ACC_LO, rv);
        expect_val("accumulate +5*6 == 42", rv, 64'sd42);

        //----------------------------------------------------
        // clear must zero it again
        //----------------------------------------------------
        bus_store(ML_CTRL, ctrl_word(0, 1, 1, LANE_64));
        bus_load (ML_ACC_LO, rv);
        expect_val("clear zeroes acc", rv, 64'd0);

        //----------------------------------------------------
        // Packed int8: 8 MACs from ONE start
        //----------------------------------------------------
        $display("-- packed int8 via MMIO (8 MACs per store) --");

        bus_store(ML_CTRL, ctrl_word(0, 1, 1, LANE_8));    // clear
        bus_store(ML_A,    64'h08_07_06_05_04_03_02_01);   // [1..8]
        bus_store(ML_B,    64'h01_01_01_01_01_01_01_01);   // [1 x 8]
        bus_store(ML_CTRL, ctrl_word(1, 0, 1, LANE_8));    // start
        bus_load (ML_ACC_LO, rv);
        expect_val("int8 [1..8].[1x8] == 36", rv, 64'sd36);

        // Sum of squares: [1..8].[1..8] = 204
        bus_store(ML_CTRL, ctrl_word(0, 1, 1, LANE_8));
        bus_store(ML_A,    64'h08_07_06_05_04_03_02_01);
        bus_store(ML_B,    64'h08_07_06_05_04_03_02_01);
        bus_store(ML_CTRL, ctrl_word(1, 0, 1, LANE_8));
        bus_load (ML_ACC_LO, rv);
        expect_val("int8 sum of squares == 204", rv, 64'sd204);

        //----------------------------------------------------
        // Signed vs unsigned, same bits
        //----------------------------------------------------
        $display("-- signed vs unsigned --");

        bus_store(ML_CTRL, ctrl_word(0, 1, 1, LANE_8));
        bus_store(ML_A,    64'hFF_FF_FF_FF_FF_FF_FF_FF);
        bus_store(ML_B,    64'h01_01_01_01_01_01_01_01);
        bus_store(ML_CTRL, ctrl_word(1, 0, 1, LANE_8));    // signed
        bus_load (ML_ACC_LO, rv);
        expect_val("int8 signed (-1 x 1) x8 == -8", rv, -64'sd8);

        bus_store(ML_CTRL, ctrl_word(0, 1, 0, LANE_8));
        bus_store(ML_A,    64'hFF_FF_FF_FF_FF_FF_FF_FF);
        bus_store(ML_B,    64'h01_01_01_01_01_01_01_01);
        bus_store(ML_CTRL, ctrl_word(1, 0, 0, LANE_8));    // unsigned
        bus_load (ML_ACC_LO, rv);
        expect_val("int8 unsigned (255 x 1) x8 == 2040", rv, 64'sd2040);

        //----------------------------------------------------
        // The 128-bit accumulator must be readable in two halves
        //----------------------------------------------------
        $display("-- 128-bit accumulator across two registers --");

        bus_store(ML_CTRL, ctrl_word(0, 1, 1, LANE_64));
        bus_store(ML_A,    64'h0000010000000000);   // 2^40
        bus_store(ML_B,    64'h0000010000000000);   // 2^40
        bus_store(ML_CTRL, ctrl_word(1, 0, 1, LANE_64));

        // 2^40 * 2^40 = 2^80. Low 64 bits are zero; bit 80 lives in the HIGH half
        // at bit (80-64) = 16.
        bus_load(ML_ACC_LO, rv);
        expect_val("2^80 low half == 0", rv, 64'd0);
        bus_load(ML_ACC_HI, rv);
        expect_val("2^80 high half == 1<<16", rv, 64'h0000000000010000);

        //----------------------------------------------------
        // THE REAL THING: a full 64-element int8 dot product,
        // driven purely through the memory-mapped interface,
        // the way software will do it.
        //----------------------------------------------------
        $display("-- 64-element int8 dot product via MMIO --");
        begin : dotprod
            reg [7:0]        va [0:63];
            reg [7:0]        vb [0:63];
            reg [XLEN-1:0]   pa, pb;
            reg signed [63:0] expected;
            integer j, k;

            expected = 0;
            for (j = 0; j < 64; j = j + 1) begin
                va[j] = j - 32;         // -32 .. 31
                vb[j] = (j % 7) - 3;    // -3 .. 3
                expected = expected + ($signed(va[j]) * $signed(vb[j]));
            end

            // Software sequence: clear, then 8 chunks of 8 elements.
            bus_store(ML_CTRL, ctrl_word(0, 1, 1, LANE_8));

            for (j = 0; j < 8; j = j + 1) begin
                for (k = 0; k < 8; k = k + 1) begin
                    pa[k*8 +: 8] = va[j*8 + k];
                    pb[k*8 +: 8] = vb[j*8 + k];
                end
                bus_store(ML_A,    pa);
                bus_store(ML_B,    pb);
                bus_store(ML_CTRL, ctrl_word(1, 0, 1, LANE_8));
            end

            bus_load(ML_ACC_LO, rv);
            $display("     8 chunks x 8 lanes = 64 MACs");
            expect_val("64-element int8 dot product", rv, expected);
        end

        //----------------------------------------------------
        // Read-only registers must not be writable
        //----------------------------------------------------
        $display("-- read-only enforcement --");

        bus_store(ML_CTRL, ctrl_word(0, 1, 1, LANE_64));   // clear -> acc = 0
        bus_store(ML_ACC_LO, 64'hFFFFFFFF_FFFFFFFF);       // try to clobber acc
        bus_load (ML_ACC_LO, rv);
        expect_val("ML_ACC_LO is read-only", rv, 64'd0);

        //----------------------------------------------------
        $display("================================================");
        $display("CHECKS: %0d   ERRORS: %0d", checks, errors);
        if (errors == 0)
            $display("RESULT: ALL ML ACCEL TESTS PASSED");
        else
            $display("RESULT: ML ACCEL TESTS FAILED");
        $display("================================================");
        $finish;
    end

endmodule
