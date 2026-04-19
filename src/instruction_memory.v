//================================================================================
// Instruction Memory (ROM) - RV32I Style Fetch Memory
//================================================================================
// Read-only instruction memory for a single-cycle RV32-style CPU.
//
// FEATURES:
//   - 32-bit architectural address input
//   - 32-bit instruction output
//   - Combinational read for single-cycle fetch
//   - Program initialized from "program.mem"
//   - Explicit instruction misalignment detection
//   - Explicit local-ROM out-of-range detection
//   - Safe default output for invalid fetches
//
// DESIGN NOTES:
//   - The CPU uses a full 32-bit architectural PC.
//   - This ROM may be much smaller than the full address space.
//   - Only the low address bits needed to index the local ROM are used.
//   - Misaligned instruction fetches are flagged.
//   - Out-of-range fetches are flagged.
//   - This module does not implement traps/exceptions by itself.
//================================================================================

`timescale 1ns/1ns

module instruction_memory #(
    parameter ADDR_WIDTH = 10,
    parameter INST_WIDTH = 32,
    parameter PC_WIDTH   = 32
)(
    input  [PC_WIDTH-1:0]   address,              // Architectural byte address
    output [INST_WIDTH-1:0] instruction,
    output                  instr_misaligned,
    output                  instr_addr_oob
);

    //========================================================================
    // MEMORY DECLARATION
    //========================================================================
    // ROM stores 32-bit instructions.
    // Total byte span covered by this local ROM = 2^ADDR_WIDTH bytes.
    // Word count = 2^(ADDR_WIDTH-2).
    localparam integer ROM_DEPTH      = (1 << (ADDR_WIDTH - 2));
    localparam integer ROM_BYTE_SPAN  = (1 << ADDR_WIDTH);

    reg [INST_WIDTH-1:0] rom [0:ROM_DEPTH-1];

    //========================================================================
    // INITIALIZATION
    //========================================================================
    integer i;
    initial begin
        for (i = 0; i < ROM_DEPTH; i = i + 1)
            rom[i] = 32'b0;

        $readmemh("program.mem", rom);
    end

    //========================================================================
    // MISALIGNMENT DETECTION
    //========================================================================
    // RV32I (without compressed instructions) expects 4-byte aligned fetches.
    assign instr_misaligned = |address[1:0];

    //========================================================================
    // LOCAL ROM OUT-OF-RANGE DETECTION
    //========================================================================
    // The local ROM only covers addresses:
    //   0 to ROM_BYTE_SPAN - 1
    //
    // Any fetch outside this local byte span is flagged as out-of-range.
    assign instr_addr_oob = (address >= ROM_BYTE_SPAN);

    //========================================================================
    // LOCAL ROM INDEXING
    //========================================================================
    // The architectural PC is 32-bit, but the local ROM is smaller.
    // Use low address bits [ADDR_WIDTH-1:2] as the word index.
    wire [ADDR_WIDTH-3:0] word_index;
    assign word_index = address[ADDR_WIDTH-1:2];

    //========================================================================
    // SAFE FETCH
    //========================================================================
    // Return a safe default word on:
    //   - misaligned instruction fetch
    //   - out-of-range instruction fetch
    //
    // Output 0 is a safe default word, not a standards-defined NOP encoding.
    assign instruction = (instr_misaligned || instr_addr_oob) ? 32'b0
                                                              : rom[word_index];

endmodule