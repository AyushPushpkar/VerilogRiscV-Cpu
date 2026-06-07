//================================================================================
// Instruction Memory (ROM) - RV64 Style Fetch Memory
//================================================================================
// Read-only instruction memory for a single-cycle RV64-style CPU.
//
// FEATURES:
//   - ADDR_W-bit architectural address input
//   - ILEN-bit instruction output
//   - Combinational read for single-cycle fetch
//   - Program initialized from "program.mem"
//   - Explicit instruction misalignment detection
//   - Explicit local-ROM out-of-range detection
//   - Safe default output for invalid fetches
//
// DESIGN NOTES:
//   - The CPU uses an ADDR_W-bit architectural PC/address path.
//   - For standard RV64, ADDR_W = 64.
//   - This ROM may be much smaller than the full address space.
//   - Only the low address bits needed to index the local ROM are used.
//   - Misaligned instruction fetches are flagged.
//   - Out-of-range fetches are flagged.
//   - This module does not implement traps/exceptions by itself.
//================================================================================
`timescale 1ns/1ns

module instruction_memory #(
    parameter ROM_ADDR_WIDTH = 10,// local ROM byte address width
    parameter ILEN           = 32,  // RISC-V base instruction width
    parameter ADDR_W         = 64   // architectural PC/address width
)(
    input  [ADDR_W-1:0]   address,              // Architectural byte address
    output [ILEN-1:0]     instruction,
    output                  instr_misaligned,
    output                  instr_addr_oob
);

    //========================================================================
    // MEMORY DECLARATION
    //========================================================================
    // ROM stores 32-bit instructions.
    // Total byte span covered by this local ROM = 2^ROM_ADDR_WIDTH bytes.
    // Word count = 2^(ROM_ADDR_WIDTH-2).
    localparam integer ROM_DEPTH      = (1 << (ROM_ADDR_WIDTH - 2));
    localparam integer ROM_BYTE_SPAN  = (1 << ROM_ADDR_WIDTH);

    reg [ILEN-1:0] rom [0:ROM_DEPTH-1];

    //========================================================================
    // INITIALIZATION
    //========================================================================
    integer i;
    initial begin
        for (i = 0; i < ROM_DEPTH; i = i + 1)
            rom[i] = {ILEN{1'b0}};

        $readmemh("program.mem", rom);
    end

    //========================================================================
    // MISALIGNMENT DETECTION
    //========================================================================
    // RV64I (without compressed instructions) expects 4-byte aligned fetches.
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
    // Use low address bits [ROM_ADDR_WIDTH-1:2] as the word index.
    wire [ROM_ADDR_WIDTH-3:0] word_index;
    assign word_index = address[ROM_ADDR_WIDTH-1:2];

    //========================================================================
    // SAFE FETCH
    //========================================================================
    // Return a safe default word on:
    //   - misaligned instruction fetch
    //   - out-of-range instruction fetch
    //
    // Output 0 is a safe default word, not a standards-defined NOP encoding.
    assign instruction = (instr_misaligned || instr_addr_oob) ? {ILEN{1'b0}}
                                                              : rom[word_index];

endmodule