`timescale 1ns/1ns

//============================================================
// MLP with OP_MAT: a whole layer in ONE accelerator run.
//
// program_mlp.asm computes its hidden layer as separate dot
// products - one accelerator run PER NEURON, each paying the full
// MMIO handshake. matrix_tile does a matrix-vector multiply in
// one run, and it had been built, tested, and never used by any
// real workload - the same trap the packed lanes were in.
//
//   8 inputs -> 8 hidden (ReLU) -> 1 output
//
//   LAYER 1 = W1(8x8) . x(8x1)   ONE OP_MAT run
//             M=8, N=1, K=8
//
//   pre-ReLU = [10, -8, 3, 5, -10, 7, 6, -3]
//   hidden   = [10,  0, 3, 5,   0, 7, 6,  0]   <- 3 neurons clamped
//   y        = 14
//
// Without ReLU y would be -35, so the activation is strongly
// load-bearing.
//
// This also needed a DMA fix: A (the weight matrix, 8 chunks) and
// B (the input vector, 1 chunk) are DIFFERENT LENGTHS, and the DMA
// had a single shared count. ML_CNT now carries both.
//============================================================

module tb_cpu_mlp_mat;

    localparam CLK_PERIOD_NS  = 10;
    localparam MAX_CYCLES     = 3000;
    localparam STUCK_PC_LIMIT = 15;

    localparam integer N_IN     = 8;
    localparam integer N_HIDDEN = 8;

    localparam integer X_BASE  = 0;     // input vector, 1 chunk
    localparam integer W1_BASE = 8;     // 8 rows, 1 chunk each
    localparam integer W2_BASE = 72;    // output weights, 1 chunk
    localparam integer H_BASE  = 80;    // hidden, written by the program

    localparam [63:0] EXPECTED_Y     = 64'd14;
    localparam signed [63:0] Y_NO_RELU = -64'sd35;

    reg         clk;
    reg         reset;
    wire [63:0] out_port;

    integer cycle_count, stuck_pc_count;
    integer mat_runs, mat_elems, dot_runs;
    reg [63:0] last_pc;
    reg        test_done, test_pass;

    // Software model
    reg signed [7:0]  W1 [0:N_HIDDEN-1][0:N_IN-1];
    reg signed [7:0]  W2 [0:N_HIDDEN-1];
    reg signed [7:0]  x  [0:N_IN-1];
    reg signed [63:0] pre [0:N_HIDDEN-1];
    reg signed [63:0] hid [0:N_HIDDEN-1];
    reg signed [63:0] sw_y;
    integer b2;
    integer mat_errors;

    integer i, j, lane;
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
        $readmemh("program_mlp_mat.mem", uut.inst_mem.rom);

        b2 = 10;
        x[0]=2; x[1]=1; x[2]=3; x[3]=1; x[4]=2; x[5]=1; x[6]=1; x[7]=2;

        // W1: 8 rows of 8. Rows 1, 4 and 7 go negative -> ReLU fires.
        W1[0][0]= 1; W1[0][1]=-1; W1[0][2]= 2; W1[0][3]= 0;
        W1[0][4]= 1; W1[0][5]= 0; W1[0][6]=-1; W1[0][7]= 1;

        W1[1][0]=-3; W1[1][1]=-1; W1[1][2]=-1; W1[1][3]= 0;
        W1[1][4]= 0; W1[1][5]= 1; W1[1][6]= 1; W1[1][7]= 0;

        W1[2][0]= 1; W1[2][1]= 1; W1[2][2]=-1; W1[2][3]= 2;
        W1[2][4]= 0; W1[2][5]=-1; W1[2][6]= 0; W1[2][7]= 1;

        W1[3][0]= 0; W1[3][1]= 2; W1[3][2]= 1; W1[3][3]=-1;
        W1[3][4]= 1; W1[3][5]= 1; W1[3][6]=-2; W1[3][7]= 0;

        W1[4][0]=-1; W1[4][1]=-2; W1[4][2]=-1; W1[4][3]=-1;
        W1[4][4]=-1; W1[4][5]= 0; W1[4][6]= 0; W1[4][7]= 0;

        W1[5][0]= 2; W1[5][1]= 0; W1[5][2]= 1; W1[5][3]= 1;
        W1[5][4]= 0; W1[5][5]= 1; W1[5][6]= 0; W1[5][7]=-1;

        W1[6][0]= 1; W1[6][1]=-1; W1[6][2]= 0; W1[6][3]= 0;
        W1[6][4]= 2; W1[6][5]=-2; W1[6][6]= 1; W1[6][7]= 1;

        W1[7][0]= 0; W1[7][1]= 1; W1[7][2]=-1; W1[7][3]= 1;
        W1[7][4]=-1; W1[7][5]= 1; W1[7][6]= 1; W1[7][7]=-1;

        W2[0]=1; W2[1]=2; W2[2]=-1; W2[3]=1;
        W2[4]=3; W2[5]=-2; W2[6]=1; W2[7]=1;

        // ---- software reference ----
        for (j = 0; j < N_HIDDEN; j = j + 1) begin
            pre[j] = 0;
            for (i = 0; i < N_IN; i = i + 1)
                pre[j] = pre[j] + (W1[j][i] * x[i]);
            hid[j] = (pre[j] > 0) ? pre[j] : 64'sd0;
        end
        sw_y = b2;
        for (j = 0; j < N_HIDDEN; j = j + 1)
            sw_y = sw_y + (W2[j] * hid[j]);

        // ---- write into RAM ----

        // x at 0x000
        pk = 64'd0;
        for (i = 0; i < N_IN; i = i + 1) pk[i*8 +: 8] = x[i];
        for (lane = 0; lane < 8; lane = lane + 1)
            uut.d_mem.mem[X_BASE + lane] = pk[lane*8 +: 8];

        // W1 row-major, one chunk per row, at 0x008
        for (j = 0; j < N_HIDDEN; j = j + 1) begin
            pk = 64'd0;
            for (i = 0; i < N_IN; i = i + 1) pk[i*8 +: 8] = W1[j][i];
            for (lane = 0; lane < 8; lane = lane + 1)
                uut.d_mem.mem[W1_BASE + j*8 + lane] = pk[lane*8 +: 8];
        end

        // W2 at 0x048
        pk = 64'd0;
        for (j = 0; j < N_HIDDEN; j = j + 1) pk[j*8 +: 8] = W2[j];
        for (lane = 0; lane < 8; lane = lane + 1)
            uut.d_mem.mem[W2_BASE + lane] = pk[lane*8 +: 8];
    end

    initial begin
        clk            = 1'b0;
        reset          = 1'b1;
        cycle_count    = 0;
        stuck_pc_count = 0;
        mat_runs       = 0;
        mat_elems      = 0;
        dot_runs       = 0;
        mat_errors     = 0;
        last_pc        = 64'hFFFFFFFF_FFFFFFFF;
        test_done      = 1'b0;
        test_pass      = 1'b0;

        $display("================================================");
        $display("MLP with OP_MAT: a whole layer in ONE run");
        $display("================================================");
        $display("  8 inputs -> 8 hidden (ReLU) -> 1 output");
        $display("");
        $display("  LAYER 1 = W1(8x8) . x(8x1)  as ONE OP_MAT run");
        $display("            M=8, N=1, K=8");
        $display("");
        $display("  program_mlp.asm needed one run PER NEURON.");
        $display("  This needs one run PER LAYER - the handshake");
        $display("  cost is paid once instead of 8 times.");
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
        $display("OP_MAT runs     = %0d  (one for the whole hidden layer)", mat_runs);
        $display("  elements out  = %0d  (8 hidden neurons)", mat_elems);
        $display("  errors        = %0d", mat_errors);
        $display("OP_DOT runs     = %0d  (layer 2 - a single neuron)", dot_runs);
        $display("");
        $display("software: hidden = [%0d %0d %0d %0d %0d %0d %0d %0d]",
                 hid[0],hid[1],hid[2],hid[3],hid[4],hid[5],hid[6],hid[7]);
        $display("          y      = %0d", sw_y);
        $display("out_port (y)     = %0d", $signed(out_port));
        $display("expected         = %0d", EXPECTED_Y);
        $display("");
        $display("(without ReLU it would be %0d)", Y_NO_RELU);
        $display("Faults: illegal=%0b fetch=%0b mem=%0b core=%0b",
                 uut.illegal_instr, uut.fetch_fault,
                 uut.mem_fault, uut.core_fault);
        $display("");

        if (sw_y !== $signed(EXPECTED_Y))
            $display("NOTE: software model disagrees with the expectation!");

        if ($signed(out_port) == Y_NO_RELU)
            $display("RESULT: FAIL - got the no-ReLU answer. Activation skipped!");
        else if (test_pass && (mat_runs == 1) && (mat_elems == N_HIDDEN)
                 && (mat_errors == 0))
            $display("RESULT: PASS - whole hidden layer in ONE OP_MAT run");
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
    // Watch matrix_tile emit the whole hidden layer, and check
    // every element against the software model.
    //--------------------------------------------------------
    always @(posedge clk) begin
        if (!reset && !test_done) begin
            if (uut.u_ml_accel.mat_start) begin
                mat_runs = mat_runs + 1;
                $display("[%0t ns] OP_MAT: whole hidden layer, ONE run", $time);
            end

            if (uut.u_ml_accel.mat_c_valid) begin
                if (mat_elems < N_HIDDEN) begin
                    if ($signed(uut.u_ml_accel.mat_c_data) !== pre[mat_elems]) begin
                        mat_errors = mat_errors + 1;
                        $display("[%0t ns]   h%0d = %0d  FAIL (expected %0d)",
                                 $time, mat_elems,
                                 $signed(uut.u_ml_accel.mat_c_data), pre[mat_elems]);
                    end
                    else begin
                        $display("[%0t ns]   h%0d: W1[%0d].x = %+0d  ->  ReLU -> %0d%0s",
                                 $time, mat_elems, mat_elems,
                                 pre[mat_elems], hid[mat_elems],
                                 (pre[mat_elems] < 0) ? "   <-- CLAMPED" : "");
                    end
                end
                mat_elems = mat_elems + 1;
            end

            if (uut.u_ml_accel.dot_start)
                dot_runs = dot_runs + 1;

            if (uut.u_ml_accel.dot_done)
                $display("[%0t ns] layer 2: W2.hidden = %0d  ->  y = %0d",
                         $time, $signed(uut.u_ml_accel.dot_result),
                         $signed(uut.u_ml_accel.dot_result) + b2);
        end
    end

endmodule
