`timescale 1ns/1ns

//============================================================
// CPU + ML accelerator integration testbench
//
// Runs program_ml.mem on the real CPU. The program drives the
// memory-mapped accelerator with ordinary SD/LD instructions to
// compute a 16-element int8 dot product, then publishes the
// result to out_port.
//
// This is the end-to-end proof: software -> CPU -> memory bus ->
// accelerator -> result -> back to software.
//
//   a = b = [1,2,3,4,5,6,7,8, 1,2,3,4,5,6,7,8]
//   dot  = 2 * (1+4+9+16+25+36+49+64) = 2 * 204 = 408
//============================================================

module tb_cpu_ml;

    localparam CLK_PERIOD_NS  = 10;
    localparam MAX_CYCLES     = 500;
    localparam STUCK_PC_LIMIT = 15;

    localparam [63:0] EXPECTED_DOT = 64'd408;

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

    //--------------------------------------------------------
    // Load the ML program over whatever instruction_memory's
    // own $readmemh("program.mem") put there.
    //--------------------------------------------------------
    initial begin
        // Let instruction_memory's initial block run first.
        #0;
        $readmemh("program_ml.mem", uut.inst_mem.rom);
    end

    //--------------------------------------------------------
    initial begin
        clk            = 1'b0;
        reset          = 1'b1;
        cycle_count    = 0;
        stuck_pc_count = 0;
        last_pc        = 64'hFFFFFFFF_FFFFFFFF;
        test_done      = 1'b0;
        test_pass      = 1'b0;

        $display("================================================");
        $display("CPU + ML ACCELERATOR INTEGRATION TEST");
        $display("================================================");
        $display("Program: 16-element int8 dot product via MMIO");
        $display("  a = b = [1..8, 1..8]");
        $display("  expected dot product = %0d", EXPECTED_DOT);
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

        $display("Cycles       = %0d", cycle_count);
        $display("Final PC     = 0x%016h", uut.pc_out);
        $display("out_port     = %0d", out_port);
        $display("expected     = %0d", EXPECTED_DOT);
        $display("");
        $display("Accelerator accumulator = %0d",
                 $signed(uut.u_ml_accel.mac_acc));
        $display("Faults: illegal=%0b fetch=%0b mem=%0b core=%0b",
                 uut.illegal_instr, uut.fetch_fault,
                 uut.mem_fault, uut.core_fault);
        $display("");

        if (test_pass)
            $display("RESULT: PASS - dot product computed by the accelerator");
        else
            $display("RESULT: FAIL");

        $display("================================================");
        $finish;
    end

    //--------------------------------------------------------
    // Cycle counting / halt detection
    //--------------------------------------------------------
    always @(posedge clk) begin
        if (!reset && !test_done) begin
            cycle_count <= cycle_count + 1;

            if (uut.pc_out == last_pc)
                stuck_pc_count <= stuck_pc_count + 1;
            else
                stuck_pc_count <= 0;

            last_pc <= uut.pc_out;

            if (stuck_pc_count >= STUCK_PC_LIMIT) begin
                $display("[%0t ns] halt reached at PC 0x%0h", $time, uut.pc_out);
                test_done <= 1'b1;
                test_pass <= (out_port == EXPECTED_DOT) && !uut.core_fault;
            end
        end
    end

    //--------------------------------------------------------
    // Fault monitoring - any fault is a hard failure
    //--------------------------------------------------------
    always @(posedge clk) begin
        if (!reset && !test_done) begin
            if (uut.core_fault) begin
                $display("[%0t ns] ERROR: core_fault (illegal=%0b fetch=%0b mem=%0b)",
                         $time, uut.illegal_instr, uut.fetch_fault, uut.mem_fault);
                test_done <= 1'b1;
                test_pass <= 1'b0;
            end
        end
    end

    //--------------------------------------------------------
    // Watch accelerator traffic
    //--------------------------------------------------------
    always @(posedge clk) begin
        if (!reset && !test_done) begin
            if (uut.is_ml_write)
                $display("[%0t ns] ML store: reg[%0d] <= 0x%016h",
                         $time, uut.alu_result[5:3], uut.reg_read2);
            if (uut.is_ml_read)
                $display("[%0t ns] ML load:  reg[%0d] => %0d",
                         $time, uut.alu_result[5:3], $signed(uut.ml_rdata));
        end
    end

    //--------------------------------------------------------
    always @(posedge clk) begin
        if (!reset && (out_port != 64'd0))
            ; // published; reported in the summary
    end

endmodule
