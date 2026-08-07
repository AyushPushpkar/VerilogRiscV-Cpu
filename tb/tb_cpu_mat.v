`timescale 1ns/1ns

//============================================================
// CPU + matrix accelerator integration testbench
//
// Runs program_mat.mem: a real RISC-V program that fills the
// accelerator's operand buffer, issues ONE start, polls until
// done, and reads back a full 2x2 GEMM.
//
// This is the payoff for wiring dot_product and matrix_tile to
// the bus. Before, only vec_mac was reachable and software had
// to run the accumulate loop itself. Now the engine runs the
// whole matrix multiply from a single store.
//
//   A = [1 2]  B = [5 6]  C = [19 22]
//       [3 4]      [7 8]      [43 50]
//
//   sum(C) = 134  -> out_port
//============================================================

module tb_cpu_mat;

    localparam CLK_PERIOD_NS  = 10;
    localparam MAX_CYCLES     = 800;
    localparam STUCK_PC_LIMIT = 15;

    localparam [63:0] EXPECTED_SUM = 64'd134;

    reg         clk;
    reg         reset;
    wire [63:0] out_port;

    integer cycle_count;
    integer stuck_pc_count;
    reg [63:0] last_pc;
    reg        test_done;
    reg        test_pass;

    cpu_top uut (
        .clk      (clk),
        .reset    (reset),
        .out_port (out_port)
    );

    always #(CLK_PERIOD_NS/2) clk = ~clk;

    initial begin
        #0;
        $readmemh("program_mat.mem", uut.inst_mem.rom);
    end

    initial begin
        clk            = 1'b0;
        reset          = 1'b1;
        cycle_count    = 0;
        stuck_pc_count = 0;
        last_pc        = 64'hFFFFFFFF_FFFFFFFF;
        test_done      = 1'b0;
        test_pass      = 1'b0;

        $display("================================================");
        $display("CPU + MATRIX ACCELERATOR (GEMM) TEST");
        $display("================================================");
        $display("  A = [1 2]   B = [5 6]   C = [19 22]");
        $display("      [3 4]       [7 8]       [43 50]");
        $display("  expected sum(C) = %0d", EXPECTED_SUM);
        $display("------------------------------------------------");

        #(2 * CLK_PERIOD_NS);
        reset = 1'b0;

        wait (test_done || (cycle_count >= MAX_CYCLES));

        $display("------------------------------------------------");

        if (!test_done) begin
            $display("RESULT: TIMEOUT after %0d cycles", cycle_count);
            $display("  (a stuck poll loop means `done` never asserted)");
            $display("================================================");
            $finish;
        end

        $display("Cycles   = %0d", cycle_count);
        $display("out_port = %0d", out_port);
        $display("expected = %0d", EXPECTED_SUM);
        $display("Faults: illegal=%0b fetch=%0b mem=%0b core=%0b",
                 uut.illegal_instr, uut.fetch_fault,
                 uut.mem_fault, uut.core_fault);
        $display("");

        if (test_pass)
            $display("RESULT: PASS - GEMM computed by the accelerator");
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

    // Watch the accelerator run the GEMM.
    always @(posedge clk) begin
        if (!reset && !test_done) begin
            if (uut.u_ml_accel.mat_start)
                $display("[%0t ns] GEMM started (one store)", $time);
            if (uut.u_ml_accel.mat_c_valid)
                $display("[%0t ns]   engine emitted C[%0d][%0d] = %0d",
                         $time, uut.u_ml_accel.mat_c_row,
                         uut.u_ml_accel.mat_c_col,
                         $signed(uut.u_ml_accel.mat_c_data));
            if (uut.u_ml_accel.mat_done)
                $display("[%0t ns] GEMM done", $time);
        end
    end

endmodule
