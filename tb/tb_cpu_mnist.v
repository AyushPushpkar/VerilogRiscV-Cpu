`timescale 1ns/1ns

//============================================================
// MNIST-scale linear regression: 784 features, SOFTWARE TILED.
//
// 784 features (a 28x28 image) is 98 packed int8 chunks. The
// operand buffer holds 64. So the vector DOES NOT FIT - it must
// be processed in tiles, with the partial sums accumulating
// inside the 128-bit accumulator:
//
//   tile 0: chunks  0..63  (512 features)  accumulate=0
//   tile 1: chunks 64..97  (272 features)  accumulate=1
//
// This is the last piece needed to run a model at genuine scale.
// It required a real RTL change: dot_product always cleared the
// accumulator on start, so tiling was impossible until an
// `accumulate` control was added (ML_CTRL[8]).
//
//   w = [(i%7)-3], x = [(i%5)+1], b = 1000
//   w.x = 1  ->  y = 1001
//============================================================

module tb_cpu_mnist;

    localparam CLK_PERIOD_NS  = 10;
    localparam MAX_CYCLES     = 3000;
    localparam STUCK_PC_LIMIT = 15;

    localparam integer N_FEAT   = 784;
    localparam integer N_CHUNKS = 98;    // 784 / 8
    localparam integer W_BASE   = 0;
    localparam integer X_BASE   = 784;

    localparam [63:0] EXPECTED_Y = 64'd1001;

    reg         clk;
    reg         reset;
    wire [63:0] out_port;

    integer cycle_count, stuck_pc_count;
    integer dma_bursts, dot_runs, dot_cycles;
    reg [63:0] last_pc;
    reg        test_done, test_pass;

    // Software model - built here, and cross-checked against the hardware.
    reg signed [7:0]  w  [0:N_FEAT-1];
    reg signed [7:0]  xf [0:N_FEAT-1];
    reg signed [63:0] sw_dot;

    integer i, lane, chunk;
    reg [63:0] pw, px;

    cpu_top uut (
        .clk      (clk),
        .reset    (reset),
        .out_port (out_port)
    );

    always #(CLK_PERIOD_NS/2) clk = ~clk;

    //--------------------------------------------------------
    // Preload the program and the packed model into RAM.
    //--------------------------------------------------------
    initial begin
        #0;
        $readmemh("program_mnist.mem", uut.inst_mem.rom);

        sw_dot = 0;
        for (i = 0; i < N_FEAT; i = i + 1) begin
            w[i]   = (i % 7) - 3;
            xf[i]  = (i % 5) + 1;
            sw_dot = sw_dot + (w[i] * xf[i]);
        end

        // Pack 8 int8 per doubleword, lane 0 = low byte.
        for (chunk = 0; chunk < N_CHUNKS; chunk = chunk + 1) begin
            pw = 64'd0;
            px = 64'd0;
            for (lane = 0; lane < 8; lane = lane + 1) begin
                pw[lane*8 +: 8] = w [chunk*8 + lane];
                px[lane*8 +: 8] = xf[chunk*8 + lane];
            end
            for (lane = 0; lane < 8; lane = lane + 1) begin
                uut.d_mem.mem[W_BASE + chunk*8 + lane] = pw[lane*8 +: 8];
                uut.d_mem.mem[X_BASE + chunk*8 + lane] = px[lane*8 +: 8];
            end
        end
    end

    initial begin
        clk            = 1'b0;
        reset          = 1'b1;
        cycle_count    = 0;
        stuck_pc_count = 0;
        dma_bursts     = 0;
        dot_runs       = 0;
        dot_cycles     = 0;
        last_pc        = 64'hFFFFFFFF_FFFFFFFF;
        test_done      = 1'b0;
        test_pass      = 1'b0;

        $display("================================================");
        $display("MNIST-SCALE LINEAR REGRESSION (784 features)");
        $display("================================================");
        $display("  784 features = 98 packed int8 chunks");
        $display("  operand buffer holds 64 -> DOES NOT FIT");
        $display("");
        $display("  tile 0: chunks  0..63  (512 features)  accumulate=0");
        $display("  tile 1: chunks 64..97  (272 features)  accumulate=1");
        $display("");
        $display("  scalar would need   ~3136 instructions");
        $display("  accelerator needs      35 instructions");
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
        $display("DMA bursts      = %0d  (one per tile)", dma_bursts);
        $display("Dot runs        = %0d  (one per tile)", dot_runs);
        $display("Dot MAC cycles  = %0d  (should be 64 + 34 = 98)", dot_cycles);
        $display("");
        $display("software model w.x = %0d", sw_dot);
        $display("out_port (y)       = %0d", $signed(out_port));
        $display("expected           = %0d", EXPECTED_Y);
        $display("Faults: illegal=%0b fetch=%0b mem=%0b core=%0b",
                 uut.illegal_instr, uut.fetch_fault,
                 uut.mem_fault, uut.core_fault);
        $display("");

        if ((sw_dot + 64'sd1000) !== $signed(EXPECTED_Y))
            $display("NOTE: software model disagrees with the expectation!");

        if (test_pass && (dot_cycles == N_CHUNKS) && (dot_runs == 2))
            $display("RESULT: PASS - 784 features via 2 tiles, %0d MAC cycles",
                     dot_cycles);
        else if (test_pass)
            $display("RESULT: PASS (but %0d dot runs / %0d cycles - expected 2 / 98)",
                     dot_runs, dot_cycles);
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
                test_pass <= (out_port == EXPECTED_Y) && !uut.core_fault;
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

    always @(posedge clk) begin
        if (!reset && !test_done) begin
            if (uut.u_ml_accel.dma_pulse) begin
                dma_bursts = dma_bursts + 1;
                $display("[%0t ns] tile %0d: DMA fetch", $time, dma_bursts-1);
            end

            if (uut.u_ml_accel.dot_start) begin
                dot_runs = dot_runs + 1;
                $display("[%0t ns] tile %0d: dot start (accumulate=%0b)",
                         $time, dot_runs-1, uut.u_ml_accel.accum_now);
            end

            if (uut.u_ml_accel.u_dot.mac_en)
                dot_cycles = dot_cycles + 1;

            if (uut.u_ml_accel.dot_done)
                $display("[%0t ns]   running total = %0d",
                         $time, $signed(uut.u_ml_accel.dot_result));
        end
    end

endmodule
