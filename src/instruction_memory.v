//================================================================================
// Instruction Memory (ROM) - 8-bit CPU Component
//================================================================================
// Read-only instruction storage. Provides combinational (immediate) access.
// Initialized with zeros then loads program from "program.mem" file.
//
// ARCHITECTURE:
//   Capacity: 256 instructions (8-bit address space)
//   Width: 32 bits per instruction (RISC-V style)
//   Access: Combinational (no clock required)
//
// INSTRUCTION FORMAT (32-bit):
//   [31:28] opcode | [27:24] funct | [23:21] rd | [20:18] rs1
//   [17:15] rs2    | [7:0] immediate
//================================================================================
// INPUT: address (8-bit)  | OUTPUT: instruction (32-bit)
//================================================================================

`timescale 1ns/1ns

module instruction_memory #(
    parameter ADDR_WIDTH = 8,
    parameter INST_WIDTH = 32 // Matches our RISC-V style layout
)(
    input [ADDR_WIDTH-1:0] address,
    output [INST_WIDTH-1:0] instruction
);

    // 256 entries, each 32 bits wide
    reg [INST_WIDTH-1:0] rom [0:(1<<ADDR_WIDTH)-1];

    // 1. Initialize memory with 0s to avoid 'X' states in GTKWave
    integer i;
    initial begin
        
        for (i = 0; i < (1<<ADDR_WIDTH); i = i + 1) begin
            rom[i] = 32'h00000000; 
        end

        // 2. Load your program
        // This will look for "program.mem" in your project folder
        $readmemh("program.mem", rom);
    end

    // Asynchronous Read: The "Best" way for a beginner Single-Cycle CPU
    // The instruction is available to the Control Unit IMMEDIATELY
    assign instruction = rom[address];

endmodule