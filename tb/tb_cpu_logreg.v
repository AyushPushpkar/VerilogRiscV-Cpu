`timescale 1ns/1ns

//============================================================
// Logistic regression - binary classification.
//
// Rung 2 of ML_POST_ROADMAP.md. The dot product is IDENTICAL to
// linear regression; the new part is turning z into a class and
// a probability without floating point.
//
//   z = w.x + b        <- accelerator, unchanged
//   class = (z > 0)    <- FREE: sigmoid(z) > 0.5 <=> z > 0
//   P     = LUT[z]     <- sigmoid precomputed in Q8 fixed point
//
// Model: 8 int8 features, w = [1,-1,1,-1,1,-1,1,-1], b = 0
//
//   x0: z = +4  ->  class 1,  P = 251/256
//   x1: z = -5  ->  class 0,  P =   2/256
//   x2: z = +1  ->  class 1,  P = 187/256
//   x3: z = -1  ->  class 0,  P =  69/256
//
//   positives = 2,  sum of P = 509  <- published
//
// Publishing the SUM OF PROBABILITIES rather than the class count
// is deliberate: it depends on every LUT lookup being right, not
// just the sign of each z.
//============================================================

module tb_cpu_logreg;

    localparam CLK_PERIOD_NS  = 10;
    localparam MAX_CYCLES     = 2000;
    localparam STUCK_PC_LIMIT = 15;

    localparam integer N_SAMPLES = 4;
    localparam integer W_BASE    = 0;      // weights
    localparam integer X_BASE    = 8;      // samples, 1 chunk each
    localparam integer LUT_BASE  = 256;    // 0x100

    localparam [63:0] EXPECTED_SUM_P = 64'd509;

    reg         clk;
    reg         reset;
    wire [63:0] out_port;

    integer cycle_count, stuck_pc_count, n_dots;
    reg [63:0] last_pc;
    reg        test_done, test_pass;

    // Software model
    reg signed [7:0]  w  [0:7];
    reg signed [7:0]  xs [0:N_SAMPLES-1][0:7];
    reg signed [63:0] sw_z    [0:N_SAMPLES-1];
    reg signed [63:0] lut     [0:16];      // sigmoid, Q8, z = -8..+8
    integer            sw_pos;
    integer            sw_sum_p;
    integer            dot_errors;

    integer i, s, lane, zc;
    reg [63:0] pk;

    cpu_top uut (
        .clk      (clk),
        .reset    (reset),
        .out_port (out_port)
    );

    always #(CLK_PERIOD_NS/2) clk = ~clk;

    //--------------------------------------------------------
    // Build the model, the samples, and the sigmoid LUT, then
    // write them into RAM.
    //--------------------------------------------------------
    initial begin
        #0;
        $readmemh("program_logreg.mem", uut.inst_mem.rom);

        // Weights: alternating +1/-1
        for (i = 0; i < 8; i = i + 1)
            w[i] = (i % 2 == 0) ? 8'sd1 : -8'sd1;

        // Samples, chosen so every z lands INSIDE the LUT range - the table is
        // genuinely exercised, not just clamped.
        xs[0][0]=3; xs[0][1]=1; xs[0][2]=2; xs[0][3]=1;
        xs[0][4]=1; xs[0][5]=1; xs[0][6]=2; xs[0][7]=1;   // z = +4

        xs[1][0]=1; xs[1][1]=3; xs[1][2]=1; xs[1][3]=2;
        xs[1][4]=1; xs[1][5]=2; xs[1][6]=1; xs[1][7]=2;   // z = -5

        xs[2][0]=2; xs[2][1]=2; xs[2][2]=2; xs[2][3]=2;
        xs[2][4]=2; xs[2][5]=2; xs[2][6]=2; xs[2][7]=1;   // z = +1

        xs[3][0]=1; xs[3][1]=1; xs[3][2]=1; xs[3][3]=1;
        xs[3][4]=1; xs[3][5]=1; xs[3][6]=1; xs[3][7]=2;   // z = -1

        // Sigmoid LUT in Q8 (256 = 1.0), z = -8 .. +8.
        lut[0]=0;   lut[1]=0;   lut[2]=1;   lut[3]=2;    // z = -8..-5
        lut[4]=5;   lut[5]=12;  lut[6]=31;  lut[7]=69;   // z = -4..-1
        lut[8]=128;                                       // z =  0
        lut[9]=187; lut[10]=225; lut[11]=244; lut[12]=251; // z = +1..+4
        lut[13]=254; lut[14]=255; lut[15]=256; lut[16]=256; // z = +5..+8

        // ---- software reference ----
        sw_pos   = 0;
        sw_sum_p = 0;
        for (s = 0; s < N_SAMPLES; s = s + 1) begin
            sw_z[s] = 0;
            for (i = 0; i < 8; i = i + 1)
                sw_z[s] = sw_z[s] + (w[i] * xs[s][i]);

            if (sw_z[s] > 0) sw_pos = sw_pos + 1;

            zc = sw_z[s];
            if (zc < -8) zc = -8;
            if (zc >  8) zc =  8;
            sw_sum_p = sw_sum_p + lut[zc + 8];
        end

        // ---- write into RAM ----

        // w: one packed int8 chunk at 0x000
        pk = 64'd0;
        for (lane = 0; lane < 8; lane = lane + 1)
            pk[lane*8 +: 8] = w[lane];
        for (lane = 0; lane < 8; lane = lane + 1)
            uut.d_mem.mem[W_BASE + lane] = pk[lane*8 +: 8];

        // samples: one packed chunk each, from 0x008
        for (s = 0; s < N_SAMPLES; s = s + 1) begin
            pk = 64'd0;
            for (lane = 0; lane < 8; lane = lane + 1)
                pk[lane*8 +: 8] = xs[s][lane];
            for (lane = 0; lane < 8; lane = lane + 1)
                uut.d_mem.mem[X_BASE + s*8 + lane] = pk[lane*8 +: 8];
        end

        // LUT: 17 int64 entries at 0x100
        for (i = 0; i < 17; i = i + 1)
            for (lane = 0; lane < 8; lane = lane + 1)
                uut.d_mem.mem[LUT_BASE + i*8 + lane] = lut[i][lane*8 +: 8];
    end

    initial begin
        clk            = 1'b0;
        reset          = 1'b1;
        cycle_count    = 0;
        stuck_pc_count = 0;
        n_dots         = 0;
        dot_errors     = 0;
        last_pc        = 64'hFFFFFFFF_FFFFFFFF;
        test_done      = 1'b0;
        test_pass      = 1'b0;

        $display("================================================");
        $display("LOGISTIC REGRESSION (binary classification)");
        $display("================================================");
        $display("  z = w.x + b        <- accelerator (unchanged)");
        $display("  class = (z > 0)    <- FREE: sigmoid(z)>0.5 <=> z>0");
        $display("  P     = LUT[z]     <- sigmoid, Q8 fixed point");
        $display("");
        $display("  No floating point. No exp(). No division.");
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
        $display("Dot products   = %0d  (one per sample)", n_dots);
        $display("Per-dot errors = %0d", dot_errors);
        $display("");
        $display("software: positives = %0d, sum of P = %0d",
                 sw_pos, sw_sum_p);
        $display("out_port (sum of P) = %0d", out_port);
        $display("expected            = %0d", EXPECTED_SUM_P);
        $display("Faults: illegal=%0b fetch=%0b mem=%0b core=%0b",
                 uut.illegal_instr, uut.fetch_fault,
                 uut.mem_fault, uut.core_fault);
        $display("");

        if (sw_sum_p !== EXPECTED_SUM_P)
            $display("NOTE: software model disagrees with the expectation!");

        if (test_pass && (dot_errors == 0) && (n_dots == N_SAMPLES))
            $display("RESULT: PASS - logistic regression classified %0d samples",
                     N_SAMPLES);
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
                test_pass <= (out_port == EXPECTED_SUM_P) && !uut.core_fault;
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
    // Check each z as the accelerator produces it, and report the
    // class and probability the same way the program will.
    //--------------------------------------------------------
    integer zi;
    always @(posedge clk) begin
        if (!reset && !test_done && uut.u_ml_accel.dot_done) begin
            if (n_dots < N_SAMPLES) begin
                if ($signed(uut.u_ml_accel.dot_result) !== sw_z[n_dots]) begin
                    dot_errors = dot_errors + 1;
                    $display("[%0t ns] sample %0d: z = %0d  FAIL (expected %0d)",
                             $time, n_dots,
                             $signed(uut.u_ml_accel.dot_result), sw_z[n_dots]);
                end
                else begin
                    zi = sw_z[n_dots];
                    if (zi < -8) zi = -8;
                    if (zi >  8) zi =  8;
                    $display("[%0t ns] sample %0d: z = %+0d  ->  class %0d,  P = %0d/256",
                             $time, n_dots, sw_z[n_dots],
                             (sw_z[n_dots] > 0) ? 1 : 0,
                             lut[zi + 8]);
                end
            end
            n_dots = n_dots + 1;
        end
    end

endmodule
