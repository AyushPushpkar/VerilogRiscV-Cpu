// Register File - RV64 Integer Register File (32 x 64)
// Implements the 32 general-purpose integer registers used by RV64.
// FEATURES:
//   - Each register is XLEN bits wide
//   - For standard RV64, XLEN = 64
//   - 32 registers total: x0 to x31
//   - 2 asynchronous read ports
//   - 1 synchronous write port
//   - x0 is hardwired to zero architecturally
//
// DESIGN NOTES:
//   - Reads from x0 always return 0
//   - Writes to x0 are ignored
//   - Registers are initialized to 0 for clean simulation behavior
//   - This module does not include reset logic; architectural state reset is
//     handled at the system level as needed
//================================================================================

`timescale 1ns/1ns

module register_file #(
    parameter XLEN       = 64,
    parameter ADDR_WIDTH = 5    // 5 bits -> 32 architectural registers
)(
    input                       clk,
    input                       we,
    input      [ADDR_WIDTH-1:0] rs1,
    input      [ADDR_WIDTH-1:0] rs2,
    input      [ADDR_WIDTH-1:0] rd,
    input      [XLEN-1:0] write_data,
    output     [XLEN-1:0] read1,
    output     [XLEN-1:0] read2
);

    //========================================================================
    // REGISTER ARRAY
    //========================================================================
    localparam NUM_REGS = (1 << ADDR_WIDTH);

    reg [XLEN-1:0] registers [0:NUM_REGS-1];

    //========================================================================
    // INITIALIZATION
    //========================================================================
    // Zero-initialize registers for deterministic simulation startup.
    integer i;
    initial begin
        for (i = 0; i < NUM_REGS; i = i + 1)
            registers[i] = {XLEN{1'b0}};
    end

    //========================================================================
    // ASYNCHRONOUS READ PORTS
    //========================================================================
    // x0 is architecturally hardwired to zero.
    assign read1 = (rs1 == {ADDR_WIDTH{1'b0}}) ? {XLEN{1'b0}} : registers[rs1];
    assign read2 = (rs2 == {ADDR_WIDTH{1'b0}}) ? {XLEN{1'b0}} : registers[rs2];

    //========================================================================
    // SYNCHRONOUS WRITE PORT
    //========================================================================
    // Writes to x0 are ignored to preserve architectural zero behavior.
    always @(posedge clk) begin
        if (we && (rd != {ADDR_WIDTH{1'b0}})) begin
            registers[rd] <= write_data;
        end
    end

endmodule