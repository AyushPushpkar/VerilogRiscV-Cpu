//================================================================================
// Data Memory (RAM) - RV64I Load/Store Aware (Single-Cycle CPU)
//================================================================================
// Byte-addressed data memory with support for RV64I load/store widths.
//
// SUPPORTED LOADS:
//   LB, LH, LW, LD, LBU, LHU, LWU
//
// SUPPORTED STORES:
//   SB, SH, SW, SD
//
// FEATURES:
//   - Byte-addressed memory array
//   - Asynchronous read path for single-cycle load behavior
//   - Synchronous write path for stores
//   - Misalignment detection outputs
//   - Out-of-bounds detection outputs
//   - Safe default read behavior when access is disabled / invalid
//================================================================================

`timescale 1ns/1ns
`include "defines.v"

module data_memory #(
    parameter ADDR_WIDTH = 8,     // local byte address width
    parameter XLEN       = 64     // data width for RV64
)(
    input                       clk,
    input                       mem_read,
    input                       mem_write,
    input      [2:0]            funct3,
    input      [XLEN-1:0]       address,       // Full 64-bit address for bounds checking
    input      [XLEN-1:0]       write_data,

    output reg [XLEN-1:0]       read_data,
    output reg                  misaligned_access,
    output reg                  illegal_funct3,
    output reg                  addr_oob,

    //========================================================================
    // SECOND READ PORT - for the ML accelerator's DMA engine
    //========================================================================
    // A read-only doubleword port, independent of the CPU's port above.
    //
    // Safe to add without arbitration: the accelerator only uses it while it is
    // busy, and the CPU is stalled polling ML_STATUS during that window. The
    // memory is asynchronous-read, so this is just a second combinational view
    // of the same array - no extra storage, no write path, and the CPU's port is
    // completely unaffected.
    //
    // Fault checking is deliberately NOT replicated here: the DMA reads whole
    // doublewords at aligned addresses by construction.
    input      [ADDR_WIDTH-1:0] dma_addr,      // byte address, doubleword-aligned
    output     [XLEN-1:0]       dma_rdata,

    //========================================================================
    // DMA WRITE PORT - for the accelerator's result write-back
    //========================================================================
    // Lets the accelerator write results straight to RAM instead of software
    // reading them back one LD at a time. Same safety argument as the read
    // port: the accelerator only writes while it is busy, and the CPU is
    // stalled polling ML_STATUS during that window, so the two never contend.
    //
    // Doubleword-only and aligned by construction, so no width decode or fault
    // checking is needed here.
    input                       dma_we,
    input      [ADDR_WIDTH-1:0] dma_waddr,
    input      [XLEN-1:0]       dma_wdata
);

    //========================================================================
    // MEMORY DECLARATION
    //========================================================================
    // Total memory size = 2^ADDR_WIDTH bytes.
    localparam integer MEM_BYTES = (1 << ADDR_WIDTH);

    reg [7:0] mem [0:MEM_BYTES-1];

    // Local index to safely route the masked address into the internal array
    wire [ADDR_WIDTH-1:0] local_idx = address[ADDR_WIDTH-1:0];

    //========================================================================
    // INITIALIZATION
    //========================================================================
    integer i;
    initial begin
        for (i = 0; i < MEM_BYTES; i = i + 1)
            mem[i] = 8'b0;
    end

    //========================================================================
    // MISALIGNMENT / ILLEGAL FUNCT3 / OUT-OF-BOUNDS DETECTION
    //========================================================================
    always @(*) begin
        // Default everything to 0 to prevent latching
        misaligned_access = 1'b0;
        illegal_funct3    = 1'b0;
        addr_oob          = 1'b0;

        if (mem_read) begin
            case (funct3)
                `LD_LB, `LD_LBU: begin
                    misaligned_access = 1'b0;
                    addr_oob          = (address > (MEM_BYTES - 1));
                end
                `LD_LH, `LD_LHU: begin
                    misaligned_access = address[0];
                    addr_oob          = (address > (MEM_BYTES - 2));
                end
                `LD_LW, `LD_LWU: begin
                    misaligned_access = |address[1:0];
                    addr_oob          = (address > (MEM_BYTES - 4));
                end
                `LD_LD: begin
                    misaligned_access = |address[2:0];
                    addr_oob          = (address > (MEM_BYTES - 8));
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
                `ST_SD: begin
                    misaligned_access = |address[2:0];
                    addr_oob          = (address > (MEM_BYTES - 8));
                end
                default: begin
                    illegal_funct3 = 1'b1;
                end
            endcase
        end
        else begin
            // Idle state: neither reading nor writing
            misaligned_access = 1'b0;
            illegal_funct3    = 1'b0;
            addr_oob          = 1'b0;
        end
    end

    //========================================================================
    // BYTE / HALFWORD / WORD / DOUBLEWORD VIEWS
    //========================================================================
    wire [7:0] byte_at_addr = mem[local_idx];

    wire [15:0] half_at_addr =
        { mem[local_idx + 1],
          mem[local_idx + 0] };

    wire [31:0] word_at_addr =
        { mem[local_idx + 3],
          mem[local_idx + 2],
          mem[local_idx + 1],
          mem[local_idx + 0] };

    wire [63:0] double_at_addr =
        { mem[local_idx + 7],
          mem[local_idx + 6],
          mem[local_idx + 5],
          mem[local_idx + 4],
          mem[local_idx + 3],
          mem[local_idx + 2],
          mem[local_idx + 1],
          mem[local_idx + 0] };

    //========================================================================
    // DMA WRITE PORT (ML accelerator result write-back)
    //========================================================================
    // Plain little-endian doubleword write. Independent of the CPU's write
    // path above - see the port declaration for why no arbitration is needed.
    always @(posedge clk) begin
        if (dma_we) begin
            mem[dma_waddr + 0] <= dma_wdata[7:0];
            mem[dma_waddr + 1] <= dma_wdata[15:8];
            mem[dma_waddr + 2] <= dma_wdata[23:16];
            mem[dma_waddr + 3] <= dma_wdata[31:24];
            mem[dma_waddr + 4] <= dma_wdata[39:32];
            mem[dma_waddr + 5] <= dma_wdata[47:40];
            mem[dma_waddr + 6] <= dma_wdata[55:48];
            mem[dma_waddr + 7] <= dma_wdata[63:56];
        end
    end

    //========================================================================
    // SECOND READ PORT (ML accelerator DMA)
    //========================================================================
    // Plain little-endian doubleword read. No fault checking - see the port
    // declaration.
    assign dma_rdata = { mem[dma_addr + 7], mem[dma_addr + 6],
                         mem[dma_addr + 5], mem[dma_addr + 4],
                         mem[dma_addr + 3], mem[dma_addr + 2],
                         mem[dma_addr + 1], mem[dma_addr + 0] };

    //========================================================================
    // ASYNCHRONOUS READ
    //========================================================================
    always @(*) begin
        read_data = {XLEN{1'b0}};

        if (mem_read && !illegal_funct3 && !misaligned_access && !addr_oob) begin
            case (funct3)
                `LD_LB:  read_data = {{(XLEN-8){byte_at_addr[7]}}, byte_at_addr};
                `LD_LH:  read_data = {{(XLEN-16){half_at_addr[15]}}, half_at_addr};
                `LD_LW:  read_data = {{(XLEN-32){word_at_addr[31]}}, word_at_addr};
                `LD_LD:  read_data = double_at_addr;
                `LD_LBU: read_data = {{(XLEN-8){1'b0}}, byte_at_addr};
                `LD_LHU: read_data = {{(XLEN-16){1'b0}}, half_at_addr};
                `LD_LWU: read_data = {{(XLEN-32){1'b0}}, word_at_addr};
                default: read_data = {XLEN{1'b0}};
            endcase
        end
    end

    //========================================================================
    // SYNCHRONOUS WRITE
    //========================================================================
    always @(posedge clk) begin
        if (mem_write && !illegal_funct3 && !misaligned_access && !addr_oob) begin
            case (funct3)
                `ST_SB: begin
                    mem[local_idx] <= write_data[7:0];
                end
                `ST_SH: begin
                    mem[local_idx + 0] <= write_data[7:0];
                    mem[local_idx + 1] <= write_data[15:8];
                end
                `ST_SW: begin
                    mem[local_idx + 0] <= write_data[7:0];
                    mem[local_idx + 1] <= write_data[15:8];
                    mem[local_idx + 2] <= write_data[23:16];
                    mem[local_idx + 3] <= write_data[31:24];
                end
                `ST_SD: begin
                    mem[local_idx + 0] <= write_data[7:0];
                    mem[local_idx + 1] <= write_data[15:8];
                    mem[local_idx + 2] <= write_data[23:16];
                    mem[local_idx + 3] <= write_data[31:24];
                    mem[local_idx + 4] <= write_data[39:32];
                    mem[local_idx + 5] <= write_data[47:40];
                    mem[local_idx + 6] <= write_data[55:48];
                    mem[local_idx + 7] <= write_data[63:56];
                end
            endcase
        end
    end

endmodule