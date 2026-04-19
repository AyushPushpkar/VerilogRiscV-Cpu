//================================================================================
// Data Memory (RAM) - RV32I Load/Store Aware (Single-Cycle CPU)
//================================================================================
// Byte-addressed data memory with support for RV32I load/store widths.
//
// SUPPORTED LOADS:
//   LB, LH, LW, LBU, LHU
//
// SUPPORTED STORES:
//   SB, SH, SW
//
// FEATURES:
//   - Byte-addressed memory array
//   - Asynchronous read path for single-cycle load behavior
//   - Synchronous write path for stores
//   - Misalignment detection outputs
//   - Out-of-bounds detection outputs
//   - Safe default read behavior when access is disabled / invalid
//
// DESIGN NOTES:
//   - Uses byte-level storage so byte and halfword accesses are natural
//   - Misaligned accesses are detected and flagged
//   - Out-of-range accesses are detected and flagged
//   - This module does not implement traps/exceptions by itself
//   - Invalid, misaligned, or out-of-range accesses are suppressed safely
//================================================================================

`timescale 1ns/1ns
`include "defines.v"

module data_memory #(
    parameter ADDR_WIDTH = 8,     // Byte address width
    parameter DATA_WIDTH = 32
)(
    input                        clk,
    input                        mem_read,
    input                        mem_write,
    input      [2:0]             funct3,
    input      [ADDR_WIDTH-1:0]  address,       // Byte address
    input      [DATA_WIDTH-1:0]  write_data,

    output reg [DATA_WIDTH-1:0]  read_data,
    output reg                   misaligned_access,
    output reg                   illegal_funct3,
    output reg                   addr_oob
);

    //========================================================================
    // MEMORY DECLARATION
    //========================================================================
    // Total memory size = 2^ADDR_WIDTH bytes.
    localparam integer MEM_BYTES = (1 << ADDR_WIDTH);

    reg [7:0] mem [0:MEM_BYTES-1];

    //========================================================================
    // INITIALIZATION
    //========================================================================
    integer i;
    initial begin
        for (i = 0; i < MEM_BYTES; i = i + 1)
            mem[i] = 8'b0;
    end

    //========================================================================
    // ACCESS CLASSIFICATION
    //========================================================================
    wire is_lb  = (funct3 == `LD_LB);
    wire is_lh  = (funct3 == `LD_LH);
    wire is_lw  = (funct3 == `LD_LW);
    wire is_lbu = (funct3 == `LD_LBU);
    wire is_lhu = (funct3 == `LD_LHU);

    wire is_sb  = (funct3 == `ST_SB);
    wire is_sh  = (funct3 == `ST_SH);
    wire is_sw  = (funct3 == `ST_SW);

    //========================================================================
    // MISALIGNMENT / ILLEGAL FUNCT3 / OUT-OF-BOUNDS DETECTION
    //========================================================================
    // RV32I alignment expectations:
    //   byte      -> always aligned
    //   halfword  -> address[0] must be 0
    //   word      -> address[1:0] must be 00
    //
    // Bounds expectations:
    //   byte      -> address <= MEM_BYTES - 1
    //   halfword  -> address <= MEM_BYTES - 2
    //   word      -> address <= MEM_BYTES - 4
    //========================================================================
    always @(*) begin
        misaligned_access = 1'b0;
        illegal_funct3    = 1'b0;
        addr_oob          = 1'b0;

        if (mem_read) begin
            case (funct3)
                `LD_LB,
                `LD_LBU: begin
                    misaligned_access = 1'b0;
                    addr_oob          = (address > (MEM_BYTES - 1));
                end

                `LD_LH,
                `LD_LHU: begin
                    misaligned_access = address[0];
                    addr_oob          = (address > (MEM_BYTES - 2));
                end

                `LD_LW: begin
                    misaligned_access = |address[1:0];
                    addr_oob          = (address > (MEM_BYTES - 4));
                end

                default: begin
                    illegal_funct3 = 1'b1;
                end
            endcase
        end
        else if (mem_write) begin
            case (funct3)
                `ST_SB: begin
                    misaligned_access = 1'b0;
                    addr_oob          = (address > (MEM_BYTES - 1));
                end

                `ST_SH: begin
                    misaligned_access = address[0];
                    addr_oob          = (address > (MEM_BYTES - 2));
                end

                `ST_SW: begin
                    misaligned_access = |address[1:0];
                    addr_oob          = (address > (MEM_BYTES - 4));
                end

                default: begin
                    illegal_funct3 = 1'b1;
                end
            endcase
        end
    end

    //========================================================================
    // BYTE / HALFWORD / WORD VIEWS
    //========================================================================
    // Little-endian assembly:
    //   lowest address = least significant byte
    //========================================================================
    wire [7:0] byte_at_addr = mem[address];

    wire [15:0] half_at_addr =
        { mem[address + 1],
          mem[address + 0] };

    wire [DATA_WIDTH-1:0] word_at_addr =
        { mem[address + 3],
          mem[address + 2],
          mem[address + 1],
          mem[address + 0] };

    //========================================================================
    // ASYNCHRONOUS READ
    //========================================================================
    always @(*) begin
        read_data = {DATA_WIDTH{1'b0}};

        if (mem_read && !illegal_funct3 && !misaligned_access && !addr_oob) begin
            case (funct3)

                //============================================================
                // LB : sign-extend byte
                //============================================================
                `LD_LB: begin
                    read_data = {{24{byte_at_addr[7]}}, byte_at_addr};
                end

                //============================================================
                // LH : sign-extend halfword
                //============================================================
                `LD_LH: begin
                    read_data = {{16{half_at_addr[15]}}, half_at_addr};
                end

                //============================================================
                // LW : full word
                //============================================================
                `LD_LW: begin
                    read_data = word_at_addr;
                end

                //============================================================
                // LBU : zero-extend byte
                //============================================================
                `LD_LBU: begin
                    read_data = {24'b0, byte_at_addr};
                end

                //============================================================
                // LHU : zero-extend halfword
                //============================================================
                `LD_LHU: begin
                    read_data = {16'b0, half_at_addr};
                end

                default: begin
                    read_data = {DATA_WIDTH{1'b0}};
                end
            endcase
        end
    end

    //========================================================================
    // SYNCHRONOUS WRITE
    //========================================================================
    // Stores are suppressed on:
    //   - invalid funct3
    //   - misaligned access
    //   - out-of-bounds access
    //========================================================================
    always @(posedge clk) begin
        if (mem_write && !illegal_funct3 && !misaligned_access && !addr_oob) begin
            case (funct3)

                //============================================================
                // SB : store byte
                //============================================================
                `ST_SB: begin
                    mem[address] <= write_data[7:0];
                end

                //============================================================
                // SH : store halfword
                //============================================================
                `ST_SH: begin
                    mem[address + 0] <= write_data[7:0];
                    mem[address + 1] <= write_data[15:8];
                end

                //============================================================
                // SW : store word
                //============================================================
                `ST_SW: begin
                    mem[address + 0] <= write_data[7:0];
                    mem[address + 1] <= write_data[15:8];
                    mem[address + 2] <= write_data[23:16];
                    mem[address + 3] <= write_data[31:24];
                end

                default: begin
                    // No write for unsupported store encoding
                end
            endcase
        end
    end

endmodule