`timescale 1ns/1ns

//============================================================
// MAC unit testbench
// Step 2 of the ML RTL order: standalone MAC block.
//
// Checks mac_unit RTL against the same software golden model
// used in tb_ml_ref.v (acc + a*b at full precision).
//============================================================

module tb_mac;

    localparam OP_WIDTH  = 64;
    localparam ACC_WIDTH = 128;

    reg                   clk;
    reg                   rst_n;
    reg                   clear;
    reg                   en;
    reg                   is_signed;
    reg  [OP_WIDTH-1:0]   a;
    reg  [OP_WIDTH-1:0]   b;
    wire [ACC_WIDTH-1:0]  acc;

    integer checks;
    integer errors;

    mac_unit #(
        .OP_WIDTH  (OP_WIDTH),
        .ACC_WIDTH (ACC_WIDTH)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .clear     (clear),
        .en        (en),
        .is_signed (is_signed),
        .a         (a),
        .b         (b),
        .acc       (acc)
    );

    // 10ns clock
    initial clk = 1'b0;
    always #5 clk = ~clk;

    //--------------------------------------------------------
    // Golden model (mirrors tb_ml_ref.v mac_ref)
    //--------------------------------------------------------
    function [ACC_WIDTH-1:0] mac_ref;
        input [OP_WIDTH-1:0]  ia;
        input [OP_WIDTH-1:0]  ib;
        input [ACC_WIDTH-1:0] iacc;
        input                 isign;
        begin
            if (isign)
                mac_ref = $signed(iacc) + ($signed(ia) * $signed(ib));
            else
                mac_ref = iacc + (ia * ib);
        end
    endfunction

    //--------------------------------------------------------
    // Helpers
    //--------------------------------------------------------

    // Drive one accumulate cycle, then compare against the golden model.
    task do_mac;
        input [255:0]         name;
        input [OP_WIDTH-1:0]  ia;
        input [OP_WIDTH-1:0]  ib;
        input                 isign;
        reg   [ACC_WIDTH-1:0] expected;
        begin
            // Predict from the accumulator value *before* the clock edge.
            expected  = mac_ref(ia, ib, acc, isign);

            a         = ia;
            b         = ib;
            is_signed = isign;
            en        = 1'b1;
            @(posedge clk);
            #1;                      // settle past the nonblocking update
            en        = 1'b0;

            checks = checks + 1;
            if (acc !== expected) begin
                errors = errors + 1;
                $display("FAIL [%0s] a=%0d b=%0d acc=%0d expected=%0d",
                         name, $signed(ia), $signed(ib),
                         $signed(acc), $signed(expected));
            end
            else begin
                $display("ok   [%0s] acc=%0d", name, $signed(acc));
            end
        end
    endtask

    task do_clear;
        begin
            clear = 1'b1;
            @(posedge clk);
            #1;
            clear = 1'b0;

            checks = checks + 1;
            if (acc !== {ACC_WIDTH{1'b0}}) begin
                errors = errors + 1;
                $display("FAIL [clear] acc=%0d expected=0", $signed(acc));
            end
            else begin
                $display("ok   [clear] acc=0");
            end
        end
    endtask

    // Check acc holds its value when en=0 (no spurious accumulation).
    task check_hold;
        reg [ACC_WIDTH-1:0] acc_prev;
        begin
            acc_prev = acc;
            en       = 1'b0;
            a        = 64'sd999;   // drive garbage; must be ignored
            b        = 64'sd999;
            @(posedge clk);
            #1;

            checks = checks + 1;
            if (acc !== acc_prev) begin
                errors = errors + 1;
                $display("FAIL [hold en=0] acc=%0d expected=%0d",
                         $signed(acc), $signed(acc_prev));
            end
            else begin
                $display("ok   [hold en=0] acc=%0d", $signed(acc));
            end
        end
    endtask

    task expect_acc;
        input [255:0]         name;
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
    // Stimulus
    //--------------------------------------------------------
    initial begin
        checks    = 0;
        errors    = 0;
        clear     = 1'b0;
        en        = 1'b0;
        is_signed = 1'b1;
        a         = {OP_WIDTH{1'b0}};
        b         = {OP_WIDTH{1'b0}};

        $display("================================================");
        $display("MAC UNIT TESTBENCH");
        $display("================================================");

        // Reset
        rst_n = 1'b0;
        @(posedge clk);
        #1;
        rst_n = 1'b1;
        expect_acc("reset clears acc", 128'sd0);

        //----------------------------------------------------
        // Golden vectors from docs/ML_TEST_PLAN.md
        //----------------------------------------------------
        $display("-- test plan MAC vectors --");

        // 3 * 4 + 0 = 12
        do_clear;
        do_mac("3x4+0", 64'sd3, 64'sd4, 1'b1);
        expect_acc("3x4+0 == 12", 128'sd12);

        // -3 * 4 + 0 = -12
        do_clear;
        do_mac("-3x4+0", -64'sd3, 64'sd4, 1'b1);
        expect_acc("-3x4+0 == -12", -128'sd12);

        // 7 * 0 + 5 = 5   (seed acc with 5 via 5*1, then MAC 7*0)
        do_clear;
        do_mac("seed 5", 64'sd5, 64'sd1, 1'b1);
        do_mac("7x0+5", 64'sd7, 64'sd0, 1'b1);
        expect_acc("7x0+5 == 5", 128'sd5);

        //----------------------------------------------------
        // Accumulation sequence: dot product [1,2,3].[4,5,6] = 32
        // Proves MAC is the primitive underneath dot product.
        //----------------------------------------------------
        $display("-- accumulate sequence (dot product) --");
        do_clear;
        do_mac("dot i=0", 64'sd1, 64'sd4, 1'b1);
        do_mac("dot i=1", 64'sd2, 64'sd5, 1'b1);
        do_mac("dot i=2", 64'sd3, 64'sd6, 1'b1);
        expect_acc("[1,2,3].[4,5,6] == 32", 128'sd32);

        //----------------------------------------------------
        // Control behavior
        //----------------------------------------------------
        $display("-- control --");
        check_hold;          // en=0 must not accumulate
        do_clear;            // clear must zero the accumulator

        //----------------------------------------------------
        // Signed vs unsigned interpretation of the same bits
        //----------------------------------------------------
        $display("-- signed vs unsigned --");

        // -1 * -1: signed = +1
        do_clear;
        do_mac("signed -1x-1", {OP_WIDTH{1'b1}}, {OP_WIDTH{1'b1}}, 1'b1);
        expect_acc("signed -1x-1 == 1", 128'sd1);

        // Same bits unsigned: (2^64-1)^2 = 2^128 - 2^65 + 1
        do_clear;
        do_mac("unsigned max*max", {OP_WIDTH{1'b1}}, {OP_WIDTH{1'b1}}, 1'b0);
        expect_acc("unsigned max*max",
                   128'hFFFFFFFF_FFFFFFFE_00000000_00000001);

        //----------------------------------------------------
        // Wide accumulation: product must not be truncated
        //----------------------------------------------------
        $display("-- wide product --");
        do_clear;
        // 2^40 * 2^40 = 2^80  (overflows 64 bits, must survive in 128-bit acc)
        do_mac("2^40 x 2^40", 64'h0000010000000000, 64'h0000010000000000, 1'b1);
        expect_acc("2^80 not truncated",
                   128'h00000000_00010000_00000000_00000000);

        //----------------------------------------------------
        // Negative accumulation crossing zero
        //----------------------------------------------------
        $display("-- signed accumulate --");
        do_clear;
        do_mac("+10x10", 64'sd10, 64'sd10, 1'b1);   // acc = 100
        do_mac("-6x30",  -64'sd6, 64'sd30, 1'b1);   // acc = 100 - 180 = -80
        expect_acc("100-180 == -80", -128'sd80);

        //----------------------------------------------------
        $display("================================================");
        $display("CHECKS: %0d   ERRORS: %0d", checks, errors);
        if (errors == 0)
            $display("RESULT: ALL MAC TESTS PASSED");
        else
            $display("RESULT: MAC TESTS FAILED");
        $display("================================================");
        $finish;
    end

endmodule
