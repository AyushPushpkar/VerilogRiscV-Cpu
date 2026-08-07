`timescale 1ns/1ns

//============================================================
// TRAINING: linear regression by gradient descent.
//
// Everything before this was INFERENCE - running a model someone
// else trained. This LEARNS the weights from data, on the
// accelerator, in integer arithmetic.
//
//   pred_q = w_q . x              <- accelerator (Q8, not truncated)
//   err_q  = pred_q - (y << 8)
//   w_q[i] -= (err_q * x[i]) >> 5   learning rate = 1/32, a SHIFT
//
// NO DIVISION. The learning rate is a right shift.
//
// THE HARD PART: integer truncation kills learning. If you truncate
// the prediction to an integer first, then once |error| < 1 the
// gradient rounds to ZERO and the weights stop moving - the loss
// plateaus far short of the answer. Keeping the error in Q8 fixes it.
//
//   task: learn w = [3, -2, 1, 4] from 4 samples, starting at [0,0,0,0]
//
//   After 150 epochs the weights converge EXACTLY.
//============================================================

module tb_cpu_train;

    localparam CLK_PERIOD_NS  = 10;
    localparam MAX_CYCLES     = 400000;
    localparam STUCK_PC_LIMIT = 15;

    localparam integer N_FEAT   = 4;
    localparam integer N_SAMP   = 4;
    localparam integer S        = 8;    // Q8 fixed point
    localparam integer SHIFT    = 5;    // learning rate = 1/32
    localparam integer EPOCHS   = 150;

    localparam integer X_BASE   = 0;    // 4 packed chunks
    localparam integer Y_BASE   = 32;   // 4 int64 targets
    localparam integer W_BASE   = 64;   // 4 int64 weights (Q8)
    localparam integer WP_BASE  = 96;   // packed learned weights

    reg         clk;
    reg         reset;
    wire [63:0] out_port;

    integer cycle_count, stuck_pc_count, n_dots;
    reg [63:0] last_pc;
    reg        test_done, test_pass;

    // The function the network must discover, and the data.
    reg signed [7:0]  w_true [0:N_FEAT-1];
    reg signed [7:0]  xs [0:N_SAMP-1][0:N_FEAT-1];
    reg signed [63:0] ys [0:N_SAMP-1];

    // Software gradient descent, run independently.
    reg signed [63:0] sw_w [0:N_FEAT-1];    // Q8
    reg signed [7:0]  sw_final [0:N_FEAT-1];
    reg [63:0]        sw_packed;

    integer e, s, i, lane;
    reg signed [63:0] pred_q, err_q, g;
    reg [63:0] pk;

    cpu_top uut (
        .clk      (clk),
        .reset    (reset),
        .out_port (out_port)
    );

    always #(CLK_PERIOD_NS/2) clk = ~clk;

    //--------------------------------------------------------
    initial begin
        #0;
        $readmemh("program_train.mem", uut.inst_mem.rom);

        // The weights to be learned.
        w_true[0] =  3;
        w_true[1] = -2;
        w_true[2] =  1;
        w_true[3] =  4;

        // Training data.
        xs[0][0]=1; xs[0][1]=2; xs[0][2]=1; xs[0][3]=1;
        xs[1][0]=2; xs[1][1]=1; xs[1][2]=0; xs[1][3]=1;
        xs[2][0]=1; xs[2][1]=0; xs[2][2]=2; xs[2][3]=1;
        xs[3][0]=0; xs[3][1]=1; xs[3][2]=1; xs[3][3]=2;

        // Ground-truth targets.
        for (s = 0; s < N_SAMP; s = s + 1) begin
            ys[s] = 0;
            for (i = 0; i < N_FEAT; i = i + 1)
                ys[s] = ys[s] + (w_true[i] * xs[s][i]);
        end

        //----------------------------------------------------
        // SOFTWARE GRADIENT DESCENT - the independent reference.
        //----------------------------------------------------
        for (i = 0; i < N_FEAT; i = i + 1)
            sw_w[i] = 0;

        for (e = 0; e < EPOCHS; e = e + 1) begin
            for (s = 0; s < N_SAMP; s = s + 1) begin
                // Q8 prediction - NOT truncated. This is the whole trick.
                pred_q = 0;
                for (i = 0; i < N_FEAT; i = i + 1)
                    pred_q = pred_q + (sw_w[i] * xs[s][i]);

                err_q = pred_q - (ys[s] <<< S);

                for (i = 0; i < N_FEAT; i = i + 1) begin
                    g = (err_q * xs[s][i]) >>> SHIFT;
                    sw_w[i] = sw_w[i] - g;
                end
            end
        end

        // De-scale, round to nearest, pack.
        sw_packed = 64'd0;
        for (i = 0; i < N_FEAT; i = i + 1) begin
            sw_final[i] = (sw_w[i] + 128) >>> S;
            sw_packed[i*8 +: 8] = sw_final[i];
        end

        //----------------------------------------------------
        // Write the data into RAM.
        //----------------------------------------------------

        // x samples: one packed int8 chunk each
        for (s = 0; s < N_SAMP; s = s + 1) begin
            pk = 64'd0;
            for (i = 0; i < N_FEAT; i = i + 1)
                pk[i*8 +: 8] = xs[s][i];
            for (lane = 0; lane < 8; lane = lane + 1)
                uut.d_mem.mem[X_BASE + s*8 + lane] = pk[lane*8 +: 8];
        end

        // y targets: int64
        for (s = 0; s < N_SAMP; s = s + 1)
            for (lane = 0; lane < 8; lane = lane + 1)
                uut.d_mem.mem[Y_BASE + s*8 + lane] = ys[s][lane*8 +: 8];

        // The program zeroes the weights itself.
    end

    initial begin
        clk            = 1'b0;
        reset          = 1'b1;
        cycle_count    = 0;
        stuck_pc_count = 0;
        n_dots         = 0;
        last_pc        = 64'hFFFFFFFF_FFFFFFFF;
        test_done      = 1'b0;
        test_pass      = 1'b0;

        $display("================================================");
        $display("TRAINING: gradient descent on the accelerator");
        $display("================================================");
        $display("  Learn w from data. Start from [0,0,0,0].");
        $display("");
        $display("  pred_q = w_q . x            <- accelerator");
        $display("  err_q  = pred_q - (y << 8)");
        $display("  w_q   -= (err_q * x) >> 5   <- lr = 1/32, a SHIFT");
        $display("");
        $display("  NO DIVISION. The learning rate is a right shift.");
        $display("");
        $display("  Weights and error are kept in Q8 fixed point. Truncating");
        $display("  the prediction to an integer first makes learning STALL:");
        $display("  once |error| < 1 the gradient rounds to zero.");
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

        $display("Cycles         = %0d  (%0d epochs x %0d samples)",
                 cycle_count, EPOCHS, N_SAMP);
        $display("Dot products   = %0d  (one prediction per sample per epoch)",
                 n_dots);
        $display("");
        $display("  true weights     = [%0d, %0d, %0d, %0d]",
                 w_true[0], w_true[1], w_true[2], w_true[3]);
        $display("  software learned = [%0d, %0d, %0d, %0d]",
                 sw_final[0], sw_final[1], sw_final[2], sw_final[3]);
        $display("  hardware learned = [%0d, %0d, %0d, %0d]",
                 $signed(out_port[7:0]),   $signed(out_port[15:8]),
                 $signed(out_port[23:16]), $signed(out_port[31:24]));
        $display("");
        $display("Faults: illegal=%0b fetch=%0b mem=%0b core=%0b",
                 uut.illegal_instr, uut.fetch_fault,
                 uut.mem_fault, uut.core_fault);
        $display("");

        if (out_port[31:0] !== sw_packed[31:0])
            $display("RESULT: FAIL - hardware and software disagree");
        else if (($signed(out_port[7:0])   === w_true[0]) &&
                 ($signed(out_port[15:8])  === w_true[1]) &&
                 ($signed(out_port[23:16]) === w_true[2]) &&
                 ($signed(out_port[31:24]) === w_true[3]) &&
                 !uut.core_fault)
            $display("RESULT: PASS - the network LEARNED w = [3,-2,1,4] from data");
        else
            $display("RESULT: FAIL - did not converge to the true weights");

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
                test_pass <= !uut.core_fault;
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
        if (!reset && !test_done && uut.u_ml_accel.dot_done)
            n_dots = n_dots + 1;
    end

endmodule
