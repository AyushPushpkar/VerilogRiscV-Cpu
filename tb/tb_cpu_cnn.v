`timescale 1ns/1ns

//============================================================
// Small CNN: 4x4 image * 3x3 filter -> 2x2 feature map -> ReLU.
//
// Rung 6 of ML_POST_ROADMAP.md. See docs/CNN_DESIGN.md.
//
// A convolution is a sliding dot product: each output pixel is
// the filter dotted with the image window under it. The four
// windows become operand A (the matrix), the filter is operand B
// (reused across all rows, N=1) - so all four outputs come from
// ONE OP_MAT run, with the filter fetched once. That reuse is
// the defining property of a CNN.
//
// The testbench does im2col (packing the windows into RAM). The
// program drives the accelerator and applies ReLU.
//
//   conv = [-11, -1, -6, 4]
//   ReLU = [  0,  0,  0, 4]     <- 3 of 4 clamped
//   sum  = 4                    (without ReLU: -14)
//============================================================

module tb_cpu_cnn;

    localparam CLK_PERIOD_NS  = 10;
    localparam MAX_CYCLES     = 3000;
    localparam STUCK_PC_LIMIT = 15;

    localparam integer N_OUT   = 4;    // 2x2 feature map
    localparam integer K       = 9;    // 3x3 filter, flattened
    localparam integer A_BASE  = 0;    // 4 windows, 2 chunks each
    localparam integer B_BASE  = 64;   // filter, 2 chunks
    localparam integer FM_BASE = 96;   // feature map written by the program

    localparam [63:0] EXPECTED_SUM   = 64'd4;
    localparam signed [63:0] SUM_NO_RELU = -64'sd14;

    reg         clk;
    reg         reset;
    wire [63:0] out_port;

    integer cycle_count, stuck_pc_count;
    integer mat_runs, mat_elems, conv_errors;
    reg [63:0] last_pc;
    reg        test_done, test_pass;

    // The image, the filter, and the software reference.
    reg signed [7:0]  img [0:3][0:3];
    reg signed [7:0]  filt[0:8];
    reg signed [7:0]  win [0:N_OUT-1][0:8];   // im2col output
    reg signed [63:0] conv[0:N_OUT-1];        // raw convolution
    reg signed [63:0] relu[0:N_OUT-1];        // after ReLU

    integer i, j, di, dj, w, lane;
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
        $readmemh("program_cnn.mem", uut.inst_mem.rom);

        // Image (4x4)
        img[0][0]=1; img[0][1]=2; img[0][2]=0; img[0][3]=1;
        img[1][0]=0; img[1][1]=3; img[1][2]=1; img[1][3]=2;
        img[2][0]=2; img[2][1]=1; img[2][2]=4; img[2][3]=1;
        img[3][0]=1; img[3][1]=0; img[3][2]=2; img[3][3]=3;

        // Filter (3x3), flattened row-major. Negative bottom row so ReLU fires.
        filt[0]= 1; filt[1]= 0; filt[2]= 1;
        filt[3]= 0; filt[4]= 2; filt[5]= 0;
        filt[6]=-3; filt[7]= 0; filt[8]=-3;

        // ---- im2col: flatten each 3x3 window (valid conv -> 4 windows) ----
        w = 0;
        for (i = 0; i < 2; i = i + 1)
            for (j = 0; j < 2; j = j + 1) begin
                for (di = 0; di < 3; di = di + 1)
                    for (dj = 0; dj < 3; dj = dj + 1)
                        win[w][di*3 + dj] = img[i+di][j+dj];
                w = w + 1;
            end

        // ---- software reference: conv then ReLU ----
        for (w = 0; w < N_OUT; w = w + 1) begin
            conv[w] = 0;
            for (i = 0; i < K; i = i + 1)
                conv[w] = conv[w] + (win[w][i] * filt[i]);
            relu[w] = (conv[w] > 0) ? conv[w] : 64'sd0;
        end

        // ---- write operand A: 4 windows, each 9 int8 padded to 16 (2 chunks) ----
        for (w = 0; w < N_OUT; w = w + 1) begin
            // low chunk = lanes 0..7, high chunk = lane 8 + padding
            pk = 64'd0;
            for (lane = 0; lane < 8; lane = lane + 1)
                pk[lane*8 +: 8] = win[w][lane];
            for (lane = 0; lane < 8; lane = lane + 1)
                uut.d_mem.mem[A_BASE + w*16 + lane] = pk[lane*8 +: 8];

            pk = 64'd0;
            pk[0 +: 8] = win[w][8];          // lane 8; rest zero-pad
            for (lane = 0; lane < 8; lane = lane + 1)
                uut.d_mem.mem[A_BASE + w*16 + 8 + lane] = pk[lane*8 +: 8];
        end

        // ---- write operand B: filter, 9 int8 padded to 16 ----
        pk = 64'd0;
        for (lane = 0; lane < 8; lane = lane + 1)
            pk[lane*8 +: 8] = filt[lane];
        for (lane = 0; lane < 8; lane = lane + 1)
            uut.d_mem.mem[B_BASE + lane] = pk[lane*8 +: 8];

        pk = 64'd0;
        pk[0 +: 8] = filt[8];
        for (lane = 0; lane < 8; lane = lane + 1)
            uut.d_mem.mem[B_BASE + 8 + lane] = pk[lane*8 +: 8];
    end

    initial begin
        clk            = 1'b0;
        reset          = 1'b1;
        cycle_count    = 0;
        stuck_pc_count = 0;
        mat_runs       = 0;
        mat_elems      = 0;
        conv_errors    = 0;
        last_pc        = 64'hFFFFFFFF_FFFFFFFF;
        test_done      = 1'b0;
        test_pass      = 1'b0;

        $display("================================================");
        $display("SMALL CNN: 4x4 image * 3x3 filter -> 2x2 -> ReLU");
        $display("================================================");
        $display("  convolution = sliding dot product");
        $display("  4 windows = operand A, filter = operand B (reused, N=1)");
        $display("  all 4 outputs from ONE OP_MAT run - the filter is");
        $display("  fetched once and reused. That is the CNN.");
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

        $display("Cycles        = %0d", cycle_count);
        $display("OP_MAT runs   = %0d  (ONE - the filter reused across windows)",
                 mat_runs);
        $display("  conv outputs= %0d", mat_elems);
        $display("  errors      = %0d", conv_errors);
        $display("");
        $display("  software conv = [%0d, %0d, %0d, %0d]",
                 conv[0], conv[1], conv[2], conv[3]);
        $display("  after ReLU    = [%0d, %0d, %0d, %0d]",
                 relu[0], relu[1], relu[2], relu[3]);
        $display("  out_port sum  = %0d", $signed(out_port));
        $display("  expected      = %0d", EXPECTED_SUM);
        $display("");
        $display("  (without ReLU the sum would be %0d)", SUM_NO_RELU);
        $display("Faults: illegal=%0b fetch=%0b mem=%0b core=%0b",
                 uut.illegal_instr, uut.fetch_fault,
                 uut.mem_fault, uut.core_fault);
        $display("");

        if ($signed(out_port) == SUM_NO_RELU)
            $display("RESULT: FAIL - got the no-ReLU sum. Activation skipped!");
        else if (test_pass && (mat_runs == 1) && (mat_elems == N_OUT)
                 && (conv_errors == 0))
            $display("RESULT: PASS - convolution ran as one OP_MAT, ReLU applied");
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

    // Check each convolution output against the software reference, and confirm
    // they all come from a single OP_MAT run.
    always @(posedge clk) begin
        if (!reset && !test_done) begin
            if (uut.u_ml_accel.mat_start) begin
                mat_runs = mat_runs + 1;
                $display("[%0t ns] OP_MAT: all 4 conv outputs, ONE run", $time);
            end

            if (uut.u_ml_accel.mat_c_valid) begin
                if (mat_elems < N_OUT) begin
                    if ($signed(uut.u_ml_accel.mat_c_data) !== conv[mat_elems]) begin
                        conv_errors = conv_errors + 1;
                        $display("[%0t ns]   out %0d = %0d  FAIL (expected %0d)",
                                 $time, mat_elems,
                                 $signed(uut.u_ml_accel.mat_c_data), conv[mat_elems]);
                    end
                    else begin
                        $display("[%0t ns]   conv %0d = %+0d  ->  ReLU -> %0d%0s",
                                 $time, mat_elems, conv[mat_elems], relu[mat_elems],
                                 (conv[mat_elems] < 0) ? "   <-- CLAMPED" : "");
                    end
                end
                mat_elems = mat_elems + 1;
            end
        end
    end

endmodule
