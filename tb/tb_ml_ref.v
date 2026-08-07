`timescale 1ns/1ns

//============================================================
// ML reference-model testbench
// Step 1 of the ML roadmap:
//   - software golden models for MAC / dot product
//   - self-checking vectors before RTL acceleration blocks exist
//============================================================

module tb_ml_ref;

    integer checks;
    integer errors;

    function [127:0] mac_ref;
        input [63:0] a;
        input [63:0] b;
        input [127:0] acc;
        begin
            mac_ref = $signed(acc) + ($signed(a) * $signed(b));
        end
    endfunction

    function [127:0] dot3_ref;
        input [63:0] a0;
        input [63:0] a1;
        input [63:0] a2;
        input [63:0] b0;
        input [63:0] b1;
        input [63:0] b2;
        reg [127:0] acc;
        begin
            acc = 128'd0;
            acc = acc + ($signed(a0) * $signed(b0));
            acc = acc + ($signed(a1) * $signed(b1));
            acc = acc + ($signed(a2) * $signed(b2));
            dot3_ref = acc;
        end
    endfunction

    task check_mac;
        input [255:0] name;
        input [63:0] a;
        input [63:0] b;
        input [127:0] acc_in;
        input [127:0] expected;
        reg [127:0] actual;
        begin
            actual = mac_ref(a, b, acc_in);
            checks = checks + 1;
            if (actual !== expected) begin
                errors = errors + 1;
                $display("FAIL [MAC %0s] acc=%0d a=%0d b=%0d actual=%0d expected=%0d",
                         name, $signed(acc_in), $signed(a), $signed(b), $signed(actual), $signed(expected));
            end
            else begin
                $display("ok   [MAC %0s] result=%0d", name, $signed(actual));
            end
        end
    endtask

    task check_dot3;
        input [255:0] name;
        input [63:0] a0;
        input [63:0] a1;
        input [63:0] a2;
        input [63:0] b0;
        input [63:0] b1;
        input [63:0] b2;
        input [127:0] expected;
        reg [127:0] actual;
        begin
            actual = dot3_ref(a0, a1, a2, b0, b1, b2);
            checks = checks + 1;
            if (actual !== expected) begin
                errors = errors + 1;
                $display("FAIL [DOT %0s] actual=%0d expected=%0d",
                         name, $signed(actual), $signed(expected));
            end
            else begin
                $display("ok   [DOT %0s] result=%0d", name, $signed(actual));
            end
        end
    endtask

    initial begin
        checks = 0;
        errors = 0;

        $display("================================================");
        $display("ML REFERENCE MODEL TESTBENCH");
        $display("================================================");

        // MAC golden cases
        check_mac("3x4+0",   64'sd3,  64'sd4,  128'sd0,  128'sd12);
        check_mac("-3x4+0", -64'sd3,  64'sd4,  128'sd0, -128'sd12);
        check_mac("7x0+5",   64'sd7,  64'sd0,  128'sd5,  128'sd5);

        // Dot-product golden cases
        check_dot3("[1,2,3].[4,5,6]",
                   64'sd1, 64'sd2, 64'sd3,
                   64'sd4, 64'sd5, 64'sd6,
                   128'sd32);

        check_dot3("[0,0,0].[7,8,9]",
                   64'sd0, 64'sd0, 64'sd0,
                   64'sd7, 64'sd8, 64'sd9,
                   128'sd0);

        $display("================================================");
        $display("CHECKS: %0d   ERRORS: %0d", checks, errors);
        if (errors == 0)
            $display("RESULT: ALL ML REFERENCE TESTS PASSED");
        else
            $display("RESULT: ML REFERENCE TESTS FAILED");
        $display("================================================");
        $finish;
    end

endmodule
