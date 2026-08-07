`timescale 1ns/1ns

//============================================================
// CPU + DMA-fed accelerator test
//
// Runs program_dma.mem: the operands already live in RAM, and
// the accelerator FETCHES THEM ITSELF. Software issues one
// control write instead of one store per element.
//
//   a = [1..8]            at RAM 0x000
//   b = [2,2,2,2,2,2,2,2] at RAM 0x040
//   dot = 2 * 36 = 72
//
// This is the fix for the bandwidth problem that
// ML_ACCELERATOR_DESIGN section 8 warned about:
// "without this, the accelerator will stall waiting on scalar
// memory traffic."
//============================================================

module tb_cpu_dma;

    localparam CLK_PERIOD_NS  = 10;
    localparam MAX_CYCLES     = 900;
    localparam STUCK_PC_LIMIT = 15;

    localparam [63:0] EXPECTED_DOT = 64'd72;

    reg         clk;
    reg         reset;
    wire [63:0] out_port;

    integer cycle_count;
    integer stuck_pc_count;
    integer dma_reads;
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
        $readmemh("program_dma.mem", uut.inst_mem.rom);
    end

    initial begin
        clk            = 1'b0;
        reset          = 1'b1;
        cycle_count    = 0;
        stuck_pc_count = 0;
        dma_reads      = 0;
        last_pc        = 64'hFFFFFFFF_FFFFFFFF;
        test_done      = 1'b0;
        test_pass      = 1'b0;

        $display("================================================");
        $display("CPU + DMA-FED ACCELERATOR TEST");
        $display("================================================");
        $display("  a = [1..8]            at RAM 0x000");
        $display("  b = [2,2,2,2,2,2,2,2] at RAM 0x040");
        $display("  expected dot product  = %0d", EXPECTED_DOT);
        $display("");
        $display("  Software issues NO operand stores to the");
        $display("  accelerator - the DMA reads both vectors out");
        $display("  of RAM by itself.");
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

        $display("Cycles     = %0d", cycle_count);
        $display("DMA reads  = %0d  (operands fetched from RAM)", dma_reads);
        $display("out_port   = %0d", out_port);
        $display("expected   = %0d", EXPECTED_DOT);
        $display("Faults: illegal=%0b fetch=%0b mem=%0b core=%0b",
                 uut.illegal_instr, uut.fetch_fault,
                 uut.mem_fault, uut.core_fault);
        $display("");

        if (test_pass)
            $display("RESULT: PASS - accelerator fetched its own operands");
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
                test_pass <= (out_port == EXPECTED_DOT) && !uut.core_fault;
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

    // Watch the DMA do its work.
    always @(posedge clk) begin
        if (!reset && !test_done) begin
            if (uut.u_ml_accel.dma_pulse)
                $display("[%0t ns] DMA triggered by ONE store", $time);

            if (uut.u_ml_accel.dma_wr_en) begin
                dma_reads = dma_reads + 1;
                $display("[%0t ns]   DMA -> buf_%0s[%0d] = %0d",
                         $time,
                         uut.u_ml_accel.dma_wr_sel_b ? "b" : "a",
                         uut.u_ml_accel.dma_wr_idx,
                         $signed(uut.u_ml_accel.dma_rdata));
            end

            if (uut.u_ml_accel.dot_start)
                $display("[%0t ns] dot product started", $time);
            if (uut.u_ml_accel.dot_done)
                $display("[%0t ns] dot product done", $time);
        end
    end

endmodule
