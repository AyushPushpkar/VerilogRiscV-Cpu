`timescale 1ns/1ns

//============================================================
// 64-feature linear regression with PACKED int8 lanes.
//
// The 4-feature version proved the hardware works but showed no
// speedup - at 4 features the MMIO handshake costs about what
// the scalar math would.
//
// This is the workload that actually justifies the accelerator,
// and it is the first one to USE the packed lanes end to end.
// Everything before this ran LANE_64, one element per cycle -
// the 8x that the whole design is built around was never
// exercised by a real program.
//
//   w = [(i%7)-3 for i in 0..63]   range -3..3
//   x = [(i%5)+1 for i in 0..63]   range 1..5
//   b = 100
//
//   w.x = -15   ->   y = 85
//
// The model is preloaded into RAM here, exactly as a real system
// would receive a trained model. That is setup, not per-inference
// cost - the DMA re-reads it every inference at zero software cost.
//============================================================

module tb_cpu_linreg8;

    localparam CLK_PERIOD_NS  = 10;
    localparam MAX_CYCLES     = 1500;
    localparam STUCK_PC_LIMIT = 15;

    localparam [63:0] EXPECTED_Y   = 64'd85;
    localparam signed [63:0] EXPECTED_DOT = -64'sd15;

    reg         clk;
    reg         reset;
    wire [63:0] out_port;

    integer cycle_count;
    integer stuck_pc_count;
    integer dma_reads;
    integer dot_cycles;
    reg [63:0] last_pc;
    reg        test_done;
    reg        test_pass;
    reg        dot_seen;

    // Software model, for building RAM and checking the answer.
    reg signed [7:0]  w [0:63];
    reg signed [7:0]  xf[0:63];
    reg signed [63:0] sw_dot;

    integer i, lane, chunk;
    reg [63:0] packed_w, packed_x;

    cpu_top uut (
        .clk      (clk),
        .reset    (reset),
        .out_port (out_port)
    );

    always #(CLK_PERIOD_NS/2) clk = ~clk;

    //--------------------------------------------------------
    // Preload the program AND the packed model into RAM.
    //--------------------------------------------------------
    initial begin
        #0;
        $readmemh("program_linreg8.mem", uut.inst_mem.rom);

        // Build the model.
        sw_dot = 0;
        for (i = 0; i < 64; i = i + 1) begin
            w[i]  = (i % 7) - 3;      // -3 .. 3
            xf[i] = (i % 5) + 1;      //  1 .. 5
            sw_dot = sw_dot + (w[i] * xf[i]);
        end

        // Pack 8 int8 features per doubleword, lane 0 = low byte, and write
        // them into data memory: w at 0x000, x at 0x040.
        for (chunk = 0; chunk < 8; chunk = chunk + 1) begin
            packed_w = 64'd0;
            packed_x = 64'd0;
            for (lane = 0; lane < 8; lane = lane + 1) begin
                packed_w[lane*8 +: 8] = w [chunk*8 + lane];
                packed_x[lane*8 +: 8] = xf[chunk*8 + lane];
            end

            // Little-endian byte store into the RAM array.
            for (lane = 0; lane < 8; lane = lane + 1) begin
                uut.d_mem.mem[chunk*8 + lane]        = packed_w[lane*8 +: 8];
                uut.d_mem.mem[64 + chunk*8 + lane]   = packed_x[lane*8 +: 8];
            end
        end
    end

    initial begin
        clk            = 1'b0;
        reset          = 1'b1;
        cycle_count    = 0;
        stuck_pc_count = 0;
        dma_reads      = 0;
        dot_cycles     = 0;
        dot_seen       = 1'b0;
        last_pc        = 64'hFFFFFFFF_FFFFFFFF;
        test_done      = 1'b0;
        test_pass      = 1'b0;

        $display("================================================");
        $display("64-FEATURE LINEAR REGRESSION, PACKED int8");
        $display("================================================");
        $display("  64 features, 8 per doubleword -> 8 chunks");
        $display("  w = [(i%%7)-3], x = [(i%%5)+1], b = 100");
        $display("");
        $display("  scalar would need    ~260 instructions");
        $display("  accelerator needs     ~25 instructions");
        $display("");
        $display("  expected w.x = %0d", EXPECTED_DOT);
        $display("  expected y   = %0d", EXPECTED_Y);
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

        $display("Cycles         = %0d", cycle_count);
        $display("DMA reads      = %0d  (16 doublewords = 128 features)", dma_reads);
        $display("Dot cycles     = %0d  (8 chunks x 8 lanes = 64 MACs)", dot_cycles);
        $display("");
        $display("software model w.x = %0d", sw_dot);
        $display("out_port (y)       = %0d", $signed(out_port));
        $display("expected           = %0d", EXPECTED_Y);
        $display("Faults: illegal=%0b fetch=%0b mem=%0b core=%0b",
                 uut.illegal_instr, uut.fetch_fault,
                 uut.mem_fault, uut.core_fault);
        $display("");

        if (sw_dot !== EXPECTED_DOT)
            $display("NOTE: software model disagrees with the hardcoded expectation!");

        if (test_pass && (dot_cycles == 8))
            $display("RESULT: PASS - 64 features in 8 cycles via packed int8 lanes");
        else if (test_pass)
            $display("RESULT: PASS (but dot took %0d cycles, expected 8)", dot_cycles);
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

    // Count what the accelerator actually did.
    always @(posedge clk) begin
        if (!reset && !test_done) begin
            if (uut.u_ml_accel.dma_pulse)
                $display("[%0t ns] DMA: one store fetches 16 doublewords", $time);

            if (uut.u_ml_accel.dma_wr_en)
                dma_reads = dma_reads + 1;

            if (uut.u_ml_accel.dot_start) begin
                $display("[%0t ns] dot product started (LANE_8, 8 chunks)", $time);
                dot_seen = 1'b1;
            end

            // Count cycles the dot engine actually accumulates.
            if (uut.u_ml_accel.u_dot.mac_en)
                dot_cycles = dot_cycles + 1;

            if (uut.u_ml_accel.dot_done)
                $display("[%0t ns] dot done: w.x = %0d",
                         $time, $signed(uut.u_ml_accel.dot_result));
        end
    end

endmodule
