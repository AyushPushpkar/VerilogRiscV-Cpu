`timescale 1ns/1ns

//TODO iverilog -I src/ -o cpu_sim src/*.v
//TODO vvp cpu_sim

module tb_cpu();
    reg clk;
    reg reset;

    // Instantiate the CPU
    cpu_top uut (
        .clk(clk),
        .reset(reset)
    );

    // Generate Clock (10ns period = 100MHz)
    always #5 clk = ~clk;

    initial begin
        // Setup Waveform Dumping
        $dumpfile("cpu_sim.vcd");
        $dumpvars(0, tb_cpu);

        // Initialize signals
        clk = 0;
        reset = 1;

        // Hold Reset for 20ns
        #20 reset = 0;

        // Run simulation for 200ns
        #200;
        
        $display("Simulation Finished. Check cpu_sim.vcd");
        $finish;
    end
endmodule