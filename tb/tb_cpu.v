`timescale 1ns/1ns

//TODO iverilog -I src/ -o cpu_sim.vvp src/*.v tb/*.v
//TODO vvp cpu_sim.vvp
//TODO gtkwave cpu_sim.vcd

module tb_cpu();
    reg clk;
    reg reset;
    
    // Wire to capture the MMIO output from the CPU
    wire [31:0] out_port; 

    // Instantiate the CPU
    cpu_top uut (
        .clk(clk),
        .reset(reset),
        .out_port(out_port) 
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

    // Monitor the MMIO Port
    // Whenever the CPU writes to address 255, this will print to your console!
    always @(out_port) begin
        // Ignore the initial zero state at boot
        if (out_port != 32'b0) begin 
            $display("[%0t ns] MMIO WRITE DETECTED: Hardware Output = %b (Hex: %h)", $time, out_port, out_port);
        end
    end

endmodule