`timescale 1ns/1ns

//============================================================
// 2-layer MLP (multi-layer perceptron).
//
// Rung 3 of ML_POST_ROADMAP.md, and the first workload where an
// accelerator RESULT becomes an accelerator OPERAND.
//
//   4 inputs -> 3 hidden (ReLU) -> 1 output
//
//   hidden = ReLU(W1 . x)     3 dot products
//   y      = W2 . hidden + b2 1 dot product
//
// ACTIVATION: ReLU = max(0, x). On integer hardware that is a
// single branch - no lookup table, no floating point. This is why
// ReLU won over sigmoid in practice: it is almost free.
//
//   W1[0].x =   7  ->  ReLU ->  7
//   W1[1].x = -10  ->  ReLU ->  0   <- the activation actually FIRES
//   W1[2].x =   2  ->  ReLU ->  2
//
//   hidden = [7, 0, 2]
//   y = 2*7 + (-1)*0 + 3*2 + 5 = 25
//
// Without ReLU the answer would be 35, so the activation is
// load-bearing - a bug that skipped it would be caught.
//============================================================

module tb_cpu_mlp;

    localparam CLK_PERIOD_NS  = 10;
    localparam MAX_CYCLES     = 2000;
    localparam STUCK_PC_LIMIT = 15;

    localparam integer N_IN     = 4;
    localparam integer N_HIDDEN = 3;

    localparam integer X_BASE  = 0;    // input
    localparam integer W1_BASE = 8;    // 3 rows, one chunk each
    localparam integer W2_BASE = 32;   // output weights
    localparam integer H_BASE  = 40;   // hidden, written by the program

    localparam [63:0] EXPECTED_Y      = 64'd25;
    localparam [63:0] Y_WITHOUT_RELU  = 64'd35;   // if the activation were skipped

    reg         clk;
    reg         reset;
    wire [63:0] out_port;

    integer cycle_count, stuck_pc_count, n_dots;
    reg [63:0] last_pc;
    reg        test_done, test_pass;

    // Software model
    reg signed [7:0]  W1 [0:N_HIDDEN-1][0:N_IN-1];
    reg signed [7:0]  W2 [0:N_HIDDEN-1];
    reg signed [7:0]  x  [0:N_IN-1];
    reg signed [63:0] pre  [0:N_HIDDEN-1];   // pre-activation
    reg signed [63:0] hid  [0:N_HIDDEN-1];   // post-ReLU
    reg signed [63:0] sw_y;
    integer b2;

    // What the accelerator actually produced, in order.
    reg signed [63:0] seen [0:3];
    integer dot_errors;

    integer i, j, lane;
    reg [63:0] pk;

    cpu_top uut (
        .clk      (clk),
        .reset    (reset),
        .out_port (out_port)
    );

    always #(CLK_PERIOD_NS/2) clk = ~clk;

    //--------------------------------------------------------
    // Build the network and write it into RAM.
    //--------------------------------------------------------
    initial begin
        #0;
        $readmemh("program_mlp.mem", uut.inst_mem.rom);

        b2 = 5;

        // Input
        x[0] = 2; x[1] = 1; x[2] = 3; x[3] = 1;

        // Layer 1 weights
        W1[0][0]= 1; W1[0][1]=-1; W1[0][2]= 2; W1[0][3]= 0;
        W1[1][0]=-3; W1[1][1]=-1; W1[1][2]=-1; W1[1][3]= 0;   // -> negative
        W1[2][0]= 1; W1[2][1]= 1; W1[2][2]=-1; W1[2][3]= 2;

        // Layer 2 weights
        W2[0]= 2; W2[1]=-1; W2[2]= 3;

        // ---- software reference ----
        for (j = 0; j < N_HIDDEN; j = j + 1) begin
            pre[j] = 0;
            for (i = 0; i < N_IN; i = i + 1)
                pre[j] = pre[j] + (W1[j][i] * x[i]);
            hid[j] = (pre[j] > 0) ? pre[j] : 64'sd0;    // ReLU
        end

        sw_y = b2;
        for (j = 0; j < N_HIDDEN; j = j + 1)
            sw_y = sw_y + (W2[j] * hid[j]);

        // ---- write into RAM, int8 packed, one chunk each ----

        // x at 0x000 (unused lanes zero - they contribute 0*0 = 0)
        pk = 64'd0;
        for (i = 0; i < N_IN; i = i + 1)
            pk[i*8 +: 8] = x[i];
        for (lane = 0; lane < 8; lane = lane + 1)
            uut.d_mem.mem[X_BASE + lane] = pk[lane*8 +: 8];

        // W1 rows at 0x008, 0x010, 0x018
        for (j = 0; j < N_HIDDEN; j = j + 1) begin
            pk = 64'd0;
            for (i = 0; i < N_IN; i = i + 1)
                pk[i*8 +: 8] = W1[j][i];
            for (lane = 0; lane < 8; lane = lane + 1)
                uut.d_mem.mem[W1_BASE + j*8 + lane] = pk[lane*8 +: 8];
        end

        // W2 at 0x020
        pk = 64'd0;
        for (j = 0; j < N_HIDDEN; j = j + 1)
            pk[j*8 +: 8] = W2[j];
        for (lane = 0; lane < 8; lane = lane + 1)
            uut.d_mem.mem[W2_BASE + lane] = pk[lane*8 +: 8];

        // The hidden vector at 0x028 is written by the PROGRAM, not here.
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
        $display("2-LAYER MLP  (4 -> 3 ReLU -> 1)");
        $display("================================================");
        $display("  hidden = ReLU(W1 . x)     3 dot products");
        $display("  y      = W2 . hidden + b2 1 dot product");
        $display("");
        $display("  ReLU = max(0,x): ONE BRANCH. No LUT, no floating point.");
        $display("  The hidden layer's output becomes layer 2's INPUT -");
        $display("  the first time an accelerator result feeds back in.");
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
        $display("Dot products   = %0d  (3 hidden + 1 output)", n_dots);
        $display("Per-dot errors = %0d", dot_errors);
        $display("");
        $display("software: hidden = [%0d, %0d, %0d]  y = %0d",
                 hid[0], hid[1], hid[2], sw_y);
        $display("out_port (y)     = %0d", $signed(out_port));
        $display("expected         = %0d", EXPECTED_Y);
        $display("");
        $display("(without ReLU it would be %0d - so the activation matters)",
                 Y_WITHOUT_RELU);
        $display("Faults: illegal=%0b fetch=%0b mem=%0b core=%0b",
                 uut.illegal_instr, uut.fetch_fault,
                 uut.mem_fault, uut.core_fault);
        $display("");

        if (sw_y !== $signed(EXPECTED_Y))
            $display("NOTE: software model disagrees with the expectation!");

        if (out_port == Y_WITHOUT_RELU)
            $display("RESULT: FAIL - got %0d, the no-ReLU answer. Activation skipped!",
                     Y_WITHOUT_RELU);
        else if (test_pass && (dot_errors == 0) && (n_dots == 4))
            $display("RESULT: PASS - 2-layer MLP ran on the accelerator");
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

    //--------------------------------------------------------
    // Watch each dot product. The first three are the hidden layer
    // (pre-activation); the fourth is the output layer.
    //--------------------------------------------------------
    always @(posedge clk) begin
        if (!reset && !test_done && uut.u_ml_accel.dot_done) begin
            if (n_dots < 4) begin
                seen[n_dots] = $signed(uut.u_ml_accel.dot_result);

                if (n_dots < N_HIDDEN) begin
                    // Hidden layer: check the PRE-activation value.
                    if (seen[n_dots] !== pre[n_dots]) begin
                        dot_errors = dot_errors + 1;
                        $display("[%0t ns] hidden %0d: W1.x = %0d  FAIL (expected %0d)",
                                 $time, n_dots, seen[n_dots], pre[n_dots]);
                    end
                    else begin
                        $display("[%0t ns] hidden %0d: W1.x = %+0d  ->  ReLU -> %0d%0s",
                                 $time, n_dots, pre[n_dots], hid[n_dots],
                                 (pre[n_dots] < 0) ? "   <-- CLAMPED" : "");
                    end
                end
                else begin
                    // Output layer: W2 . hidden (bias added in software after).
                    $display("[%0t ns] output: W2.hidden = %0d  ->  y = %0d",
                             $time, seen[n_dots], seen[n_dots] + b2);
                end
            end
            n_dots = n_dots + 1;
        end
    end

endmodule
