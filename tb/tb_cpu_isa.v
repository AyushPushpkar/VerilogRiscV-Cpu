`timescale 1ns/1ns

//============================================================
// RV64I ISA compliance test, running on the real CPU.
//
// Runs program_isa.mem, which checks LUI sign extension, signed
// vs unsigned branch comparison, load sign extension, and x0
// hardwiring - each as a branch that jumps to `fail` on a wrong
// answer.
//
// These are datapath-level properties: the unit tests cover the
// ALU and data_memory in isolation, but only a real program
// proves control_unit routes them correctly.
//
// PASS  -> out_port = 0x555 (1365)
// FAIL  -> out_port = 0
//============================================================

module tb_cpu_isa;

    localparam CLK_PERIOD_NS  = 10;
    localparam MAX_CYCLES     = 500;
    localparam STUCK_PC_LIMIT = 15;

    localparam [63:0] EXPECT_PASS = 64'h555;

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
        $readmemh("program_isa.mem", uut.inst_mem.rom);
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
        $display("RV64I ISA COMPLIANCE TEST (on the real CPU)");
        $display("================================================");
        $display("Checks: LUI sign extension, signed vs unsigned");
        $display("        branches, load sign extension, x0 = 0");
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

        $display("Cycles   = %0d", cycle_count);
        $display("out_port = 0x%0h (%0d)", out_port, out_port);
        $display("Faults: illegal=%0b fetch=%0b mem=%0b core=%0b",
                 uut.illegal_instr, uut.fetch_fault,
                 uut.mem_fault, uut.core_fault);
        $display("");

        if (test_pass) begin
            $display("RESULT: PASS - all RV64I checks passed on hardware");
        end
        else if (out_port == 64'd0) begin
            $display("RESULT: FAIL - a compliance check jumped to `fail`");
            $display("        (out_port = 0 is the failure sentinel)");
        end
        else begin
            $display("RESULT: FAIL");
        end

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
                test_pass <= (out_port == EXPECT_PASS) && !uut.core_fault;
            end
        end
    end

    always @(posedge clk) begin
        if (!reset && !test_done && uut.core_fault) begin
            $display("[%0t ns] ERROR: core_fault (illegal=%0b fetch=%0b mem=%0b)",
                     $time, uut.illegal_instr, uut.fetch_fault, uut.mem_fault);
            test_done <= 1'b1;
            test_pass <= 1'b0;
        end
    end

endmodule
