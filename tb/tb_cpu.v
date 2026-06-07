`timescale 1ns/1ns

// TODO: iverilog -I src/ -o cpu_sim.vvp src/*.v tb/*.v
// TODO: vvp cpu_sim.vvp
// TODO: gtkwave cpu_sim.vcd

module tb_cpu();

    //====================================================================
    // TESTBENCH CONFIGURATION
    //====================================================================
    localparam CLK_PERIOD_NS  = 10;
    localparam MAX_CYCLES     = 300;
    localparam STUCK_PC_LIMIT = 15;

    //====================================================================
    // CLOCK / RESET
    //====================================================================
    reg clk;
    reg reset;

    // MMIO output captured from the CPU
    wire [63:0] out_port;

    //====================================================================
    // DUT
    //====================================================================
    cpu_top uut (
        .clk      (clk),
        .reset    (reset),
        .out_port (out_port)
    );

    //====================================================================
    // TESTBENCH STATE
    //====================================================================
    integer cycle_count;
    integer stuck_pc_count;

    reg [63:0] last_pc;
    reg [63:0] last_out_port;

    reg test_done;
    reg test_pass;

    //====================================================================
    // CLOCK GENERATION
    //====================================================================
    always #(CLK_PERIOD_NS/2) clk = ~clk;

    //====================================================================
    // MAIN TEST SEQUENCE
    //====================================================================
    initial begin
        $dumpfile("cpu_sim.vcd");
        $dumpvars(0, tb_cpu);

        clk            = 1'b0;
        reset          = 1'b1;
        cycle_count    = 0;
        stuck_pc_count = 0;
        last_pc        = 64'hFFFFFFFFFFFFFFFF;
        last_out_port  = 64'h0000000000000000;
        test_done      = 1'b0;
        test_pass      = 1'b0;

        $display("==================================================");
        $display("CPU TESTBENCH STARTED");
        $display("Clock Period   = %0d ns", CLK_PERIOD_NS);
        $display("Max Cycles     = %0d",    MAX_CYCLES);
        $display("Stuck PC Limit = %0d",    STUCK_PC_LIMIT);
        $display("==================================================");

        // Hold reset for two cycles
        #(2 * CLK_PERIOD_NS);
        reset = 1'b0;

        // Wait for end condition or timeout
        wait (test_done || (cycle_count >= MAX_CYCLES));

        if (!test_done && (cycle_count >= MAX_CYCLES)) begin
            $display("==================================================");
            $display("RESULT: TIMEOUT");
            $display("Cycles = %0d", cycle_count);
            print_state();
            $display("==================================================");
            $finish;
        end

        if (test_done && test_pass) begin
            $display("==================================================");
            $display("RESULT: PASS");
            $display("Cycles = %0d", cycle_count);
            print_state();
            $display("==================================================");
            $finish;
        end

        if (test_done && !test_pass) begin
            $display("==================================================");
            $display("RESULT: FAIL");
            $display("Cycles = %0d", cycle_count);
            print_state();
            $display("==================================================");
            $finish;
        end
    end

    //====================================================================
    // CYCLE COUNTER + PC STUCK DETECTION
    //====================================================================
    always @(posedge clk) begin
        if (!reset && !test_done) begin
            cycle_count <= cycle_count + 1;

            if (uut.pc_out == last_pc)
                stuck_pc_count <= stuck_pc_count + 1;
            else
                stuck_pc_count <= 0;

            last_pc <= uut.pc_out;

            if (stuck_pc_count >= STUCK_PC_LIMIT) begin
                $display("[%0t ns] INFO: PC stopped changing at 0x%016h", $time, uut.pc_out);

                // Treat this as a clean stop for general-purpose simulation.
                // No automatic PASS claim is made.
                test_done <= 1'b1;
                test_pass <= 1'b0;
            end
        end
    end

    //====================================================================
    // INTERNAL FAULT MONITORING
    //====================================================================
    always @(posedge clk) begin
        if (!reset && !test_done) begin
            if (uut.illegal_instr) begin
                $display("[%0t ns] ERROR: illegal_instr asserted", $time);
                test_done <= 1'b1;
                test_pass <= 1'b0;
            end

            if (uut.fetch_fault) begin
                $display("[%0t ns] ERROR: fetch_fault asserted", $time);
                test_done <= 1'b1;
                test_pass <= 1'b0;
            end

            if (uut.mem_fault) begin
                $display("[%0t ns] ERROR: mem_fault asserted", $time);
                test_done <= 1'b1;
                test_pass <= 1'b0;
            end

            if (uut.core_fault) begin
                $display("[%0t ns] ERROR: core_fault asserted", $time);
                test_done <= 1'b1;
                test_pass <= 1'b0;
            end
        end
    end

    //====================================================================
    // MMIO MONITOR
    // Whenever the CPU writes to the MMIO address this prints to console.
    //====================================================================
    always @(posedge clk) begin
        if (!reset && !test_done) begin
            if (out_port != last_out_port) begin
                if (out_port != 64'b0)
                    $display("[%0t ns] MMIO WRITE DETECTED: out_port = 0x%016h (%0d)",
                             $time, out_port, out_port);

                last_out_port <= out_port;
            end
        end
    end

    //====================================================================
    // FINAL DEBUG STATE PRINT
    //====================================================================
    task print_state;
        reg [63:0] mem_word_0;
        begin
            mem_word_0 = {uut.d_mem.mem[7], uut.d_mem.mem[6],
                          uut.d_mem.mem[5], uut.d_mem.mem[4],
                          uut.d_mem.mem[3], uut.d_mem.mem[2],
                          uut.d_mem.mem[1], uut.d_mem.mem[0]};

            $display("Final PC      = 0x%016h", uut.pc_out);
            $display("Final OUTPORT = 0x%016h", out_port);

            $display("Register Dump (sample debug view):");
            $display("x1  = 0x%016h", uut.reg_file.registers[1]);
            $display("x2  = 0x%016h", uut.reg_file.registers[2]);
            $display("x3  = 0x%016h", uut.reg_file.registers[3]);
            $display("x4  = 0x%016h", uut.reg_file.registers[4]);
            $display("x5  = 0x%016h", uut.reg_file.registers[5]);
            $display("x10 = 0x%016h", uut.reg_file.registers[10]);
            $display("x11 = 0x%016h", uut.reg_file.registers[11]);

            $display("MEM[0] = 0x%016h", mem_word_0);

            $display("Fault Summary:");
            $display("illegal_instr = %0b", uut.illegal_instr);
            $display("fetch_fault   = %0b", uut.fetch_fault);
            $display("mem_fault     = %0b", uut.mem_fault);
            $display("core_fault    = %0b", uut.core_fault);
        end
    endtask

endmodule