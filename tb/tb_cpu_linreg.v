`timescale 1ns/1ns

//============================================================
// Linear regression inference on the ML accelerator.
//
// The first REAL ML workload on this hardware - everything
// before this was synthetic vectors and toy matrices.
//
//   y = w . x + b        one dot product per prediction
//
//   w = [3, -2, 5, 1]    b = 10
//
//   x0 = [1,2,3,4] -> 18 + 10 = 28
//   x1 = [2,0,1,5] -> 16 + 10 = 26
//   x2 = [0,4,2,1] ->  3 + 10 = 13
//   x3 = [5,5,0,0] ->  5 + 10 = 15
//                              ----
//   sum of predictions          82
//
// Each loop iteration re-points the DMA at the next sample and
// fires one dot product. The weight vector never moves - the
// DMA re-fetches it from RAM every time, at zero software cost.
//============================================================

module tb_cpu_linreg;

    localparam CLK_PERIOD_NS  = 10;
    localparam MAX_CYCLES     = 2000;
    localparam STUCK_PC_LIMIT = 15;

    localparam [63:0] EXPECTED_SUM = 64'd82;
    localparam integer N_SAMPLES   = 4;

    reg         clk;
    reg         reset;
    wire [63:0] out_port;

    integer cycle_count;
    integer stuck_pc_count;
    integer n_dots;
    integer n_dma;
    reg [63:0] last_pc;
    reg        test_done;
    reg        test_pass;

    // Expected dot product for each sample, in order.
    reg signed [63:0] expect_dot [0:N_SAMPLES-1];
    integer dot_errors;

    cpu_top uut (
        .clk      (clk),
        .reset    (reset),
        .out_port (out_port)
    );

    always #(CLK_PERIOD_NS/2) clk = ~clk;

    initial begin
        #0;
        $readmemh("program_linreg.mem", uut.inst_mem.rom);
    end

    initial begin
        clk            = 1'b0;
        reset          = 1'b1;
        cycle_count    = 0;
        stuck_pc_count = 0;
        n_dots         = 0;
        n_dma          = 0;
        dot_errors     = 0;
        last_pc        = 64'hFFFFFFFF_FFFFFFFF;
        test_done      = 1'b0;
        test_pass      = 1'b0;

        expect_dot[0] = 64'sd18;
        expect_dot[1] = 64'sd16;
        expect_dot[2] = 64'sd3;
        expect_dot[3] = 64'sd5;

        $display("================================================");
        $display("LINEAR REGRESSION INFERENCE");
        $display("================================================");
        $display("  model:  y = w . x + b");
        $display("  w = [3, -2, 5, 1]   b = 10");
        $display("");
        $display("  x0 = [1,2,3,4]  ->  y = 28");
        $display("  x1 = [2,0,1,5]  ->  y = 26");
        $display("  x2 = [0,4,2,1]  ->  y = 13");
        $display("  x3 = [5,5,0,0]  ->  y = 15");
        $display("  sum of predictions  = %0d", EXPECTED_SUM);
        $display("------------------------------------------------");

        #(2 * CLK_PERIOD_NS);
        reset = 1'b0;

        wait (test_done || (cycle_count >= MAX_CYCLES));

        $display("------------------------------------------------");

        if (!test_done) begin
            $display("RESULT: TIMEOUT after %0d cycles", cycle_count);
            $display("================================================");
            $finish;
        end

        $display("Cycles          = %0d", cycle_count);
        $display("DMA fetches     = %0d  (one per sample)", n_dma);
        $display("Dot products    = %0d  (one per prediction)", n_dots);
        $display("Per-dot errors  = %0d", dot_errors);
        $display("");
        $display("out_port (sum)  = %0d", out_port);
        $display("expected        = %0d", EXPECTED_SUM);
        $display("Faults: illegal=%0b fetch=%0b mem=%0b core=%0b",
                 uut.illegal_instr, uut.fetch_fault,
                 uut.mem_fault, uut.core_fault);
        $display("");

        if (test_pass && (dot_errors == 0) && (n_dots == N_SAMPLES))
            $display("RESULT: PASS - linear regression ran on the accelerator");
        else if (n_dots != N_SAMPLES)
            $display("RESULT: FAIL - expected %0d dot products, saw %0d",
                     N_SAMPLES, n_dots);
        else
            $display("RESULT: FAIL");

        $display("================================================");
        $finish;
    end

    always @(posedge clk) begin
        if (!reset && !test_done) begin
            cycle_count <= cycle_count + 1;

            if (uut.pc_out == last_pc)
                stuck_pc_count <= stuck_pc_count + 1;
            else
                stuck_pc_count <= 0;

            last_pc <= uut.pc_out;

            if (stuck_pc_count >= STUCK_PC_LIMIT) begin
                $display("[%0t ns] halt at PC 0x%0h", $time, uut.pc_out);
                test_done <= 1'b1;
                test_pass <= (out_port == EXPECTED_SUM) && !uut.core_fault;
            end
        end
    end

    always @(posedge clk) begin
        if (!reset && !test_done && uut.core_fault) begin
            $display("[%0t ns] ERROR: core_fault", $time);
            test_done <= 1'b1;
            test_pass <= 1'b0;
        end
    end

    //--------------------------------------------------------
    // Watch each prediction as it happens, and check the dot
    // product against the model. A right SUM with wrong parts
    // would otherwise slip through.
    //--------------------------------------------------------
    always @(posedge clk) begin
        if (!reset && !test_done) begin
            if (uut.u_ml_accel.dma_pulse)
                n_dma = n_dma + 1;

            if (uut.u_ml_accel.dot_done) begin
                if (n_dots < N_SAMPLES) begin
                    if ($signed(uut.u_ml_accel.dot_result) !== expect_dot[n_dots]) begin
                        dot_errors = dot_errors + 1;
                        $display("[%0t ns] sample %0d: dot = %0d  FAIL (expected %0d)",
                                 $time, n_dots,
                                 $signed(uut.u_ml_accel.dot_result),
                                 expect_dot[n_dots]);
                    end
                    else begin
                        $display("[%0t ns] sample %0d: w.x = %0d   ->  y = %0d",
                                 $time, n_dots,
                                 $signed(uut.u_ml_accel.dot_result),
                                 $signed(uut.u_ml_accel.dot_result) + 64'sd10);
                    end
                end
                n_dots = n_dots + 1;
            end
        end
    end

endmodule
