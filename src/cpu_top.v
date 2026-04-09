//================================================================================
// CPU Top Level - 8-bit CPU Integration
//================================================================================
// Integrates all CPU components (PC, memories, register file, ALU, control unit).
// Harvard architecture (separate instruction/data memory). Single-cycle execution.
// 32-bit instructions with RISC-V style formatting.
//
// ARCHITECTURE:
//   Data width: 8 bits      | Instruction width: 32 bits
//   Address space: 8 bits   | Registers: 8 × 8-bit (R0-R7)
//   Memories: 256 × 32-bit instr, 256 × 8-bit data
//
// DATAPATH:
//   Fetch → Decode → Execute → Memory Access → Writeback
//   Multiplexers handle: ALU source (register/immediate),
//   Write-back (ALU/memory), Next PC (sequential/jump)
//================================================================================
// INPUTS: clk, reset  | MODULE INSTANCES: PC, InstrMem, RegFile, ALU, DataMem
//================================================================================

`timescale 1ns/1ns
`include "defines.v"

module cpu_top #(
    parameter DATA_WIDTH = 8,
    parameter ADDR_WIDTH = 8,
    // Automatically sets MMIO to the highest memory address (e.g., 0xFF)
    parameter MMIO_ADDRESS = {ADDR_WIDTH{1'b1}} 
)(
    input clk,
    input reset,
    output reg [DATA_WIDTH-1:0] out_port
);

    // ==========================================
    // 1. INTERNAL WIRES (The Connections)
    // ==========================================
    
    // Instruction Fetch Wires
    wire [ADDR_WIDTH-1:0] pc_out;
    wire [ADDR_WIDTH-1:0] pc_plus_4 = pc_out + 4; // RISC-V Byte Addressing
    wire [ADDR_WIDTH-1:0] next_pc_val;

    wire [31:0] instruction; // Always 32 bits
    
    wire [6:0] opcode = instruction[6:0];   // Standard RISC-V Placement
    wire [7:0] imm8   = instruction[14:7];  // 8-bit Immediate
    wire [2:0] rd     = instruction[17:15]; // 3-bit Destination Reg
    wire [2:0] rs1    = instruction[20:18]; // 3-bit Source Reg 1
    wire [2:0] rs2    = instruction[23:21]; // 3-bit Source Reg 2
    wire [3:0] funct  = instruction[27:24]; // 4-bit ALU Function

    // Safely zero-pads your 8-bit immediate up to the datapath width
    wire [DATA_WIDTH-1:0] imm = {{DATA_WIDTH-8{1'b0}}, imm8};

    // Hierarchical Decoding Wires (Level 1)
    wire is_mul_div;
    wire is_base;

    // Control Unit Signals (Level 2)
    wire reg_write, mem_read, mem_write, alu_src, jump, branch;
    wire [3:0] alu_ctrl;

    // Register & ALU Data Wires
    wire [DATA_WIDTH-1:0] reg_read1, reg_read2;
    wire [DATA_WIDTH-1:0] alu_in_b;
    wire [DATA_WIDTH-1:0] alu_result;
    wire alu_zero;

    // Memory Wires
    wire [DATA_WIDTH-1:0] ram_read_data;
    wire [DATA_WIDTH-1:0] final_write_data;

    // ==========================================
    // 2. CONTROL & ROUTING LOGIC (The MUXes)
    // ==========================================

    // ALU Source MUX: Picks Register Data 2 OR Immediate value
    assign alu_in_b = (alu_src) ? imm : reg_read2;

    // Write-Back MUX: Picks ALU Result OR RAM Data to save in Register
    assign final_write_data = (mem_read) ? ram_read_data : alu_result;

    // Next PC MUX: Standard +1 OR Jump/Branch Target
    wire take_branch = branch & alu_zero;
    assign next_pc_val = (jump | take_branch) ? imm[ADDR_WIDTH-1:0] : pc_plus_4;

    // ==========================================
    // 3. MMIO LOGIC (Memory-Mapped I/O)
    // ==========================================
    
    wire is_mmio_addr = (alu_result[ADDR_WIDTH-1:0] == MMIO_ADDRESS);
    wire ram_we = mem_write & ~is_mmio_addr;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            out_port <= {DATA_WIDTH{1'b0}};
        end else if (mem_write && is_mmio_addr) begin
            out_port <= reg_read2;
        end
    end

    // ==========================================
    // 4. MODULE INSTANTIATIONS (The Chips)
    // ==========================================

    program_counter #(.PC_WIDTH(ADDR_WIDTH)) pc_inst (
        .clk(clk),
        .reset(reset),
        .next_pc(next_pc_val),
        .pc(pc_out)
    );

    instruction_memory #(.ADDR_WIDTH(ADDR_WIDTH), .INST_WIDTH(32)) inst_mem (
        .address(pc_out),
        .instruction(instruction)
    );

    // LEVEL 1 DECODER: Evaluates instruction immediately upon fetch
    pre_decoder #(.INSTR_WIDTH(32), .OP_WIDTH(7)) pre_dec (
        .instruction(instruction),
        .is_mul_div(is_mul_div),
        .is_base(is_base)
    );

    // LEVEL 2 DECODER: Standard Control Unit
    control_unit cu (
        .opcode(opcode),
        .funct(funct),
        .reg_write(reg_write),
        .mem_read(mem_read),
        .mem_write(mem_write),
        .alu_src(alu_src),
        .jump(jump),
        .branch(branch),
        .alu_ctrl(alu_ctrl)
    );

    register_file #(.DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(3)) reg_file  (
        .clk(clk),
        .we(reg_write),
        .rs1(rs1),
        .rs2(rs2),
        .rd(rd),
        .write_data(final_write_data), // From Write-Back MUX
        .read1(reg_read1),
        .read2(reg_read2)
    );

    alu #(.DATA_WIDTH(DATA_WIDTH), .OP_WIDTH(4)) main_alu (
        .A(reg_read1),
        .B(alu_in_b), // From ALU Source MUX
        .is_mul_div(is_mul_div), // Route Level 1 enable signal to ALU
        .alu_operation_code(alu_ctrl),
        .result(alu_result),
        .zero(alu_zero)
    );

    data_memory #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH)) d_mem (
        .clk(clk),
        .mem_read(mem_read),
        .mem_write(ram_we), // FIXED: Protects RAM from MMIO writes
        .address(alu_result[ADDR_WIDTH-1:0]), // ALU calculates the address
        .write_data(reg_read2), // Data to save comes from RS2
        .read_data(ram_read_data)
    );

endmodule