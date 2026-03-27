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

module cpu_top (
    input clk,
    input reset
);

    // ==========================================
    // 1. INTERNAL WIRES (The Connections)
    // ==========================================
    
    // Instruction Fetch Wires
    wire [7:0] pc_out;
    wire [7:0] pc_plus_1 = pc_out + 1;
    wire [7:0] next_pc_val;
    wire [31:0] instruction;

    // Decoding Wires (Slicing the 32-bit instruction)
    wire [3:0] opcode = instruction[31:28];
    wire [3:0] funct  = instruction[27:24];
    wire [2:0] rd     = instruction[23:21];
    wire [2:0] rs1    = instruction[20:18];
    wire [2:0] rs2    = instruction[17:15];
    wire [7:0] imm    = instruction[7:0];

    // Control Unit Signals
    wire reg_write, mem_read, mem_write, alu_src, jump, branch;
    wire [3:0] alu_ctrl;

    // Register & ALU Data Wires
    wire [7:0] reg_read1, reg_read2;
    wire [7:0] alu_in_b;
    wire [7:0] alu_result;
    wire alu_zero;

    // Memory & Write-Back Wires
    wire [7:0] ram_read_data;
    wire [7:0] final_write_data;

    // ==========================================
    // 2. CONTROL & ROUTING LOGIC (The MUXes)
    // ==========================================

    // ALU Source MUX: Picks Register Data 2 OR Immediate value
    assign alu_in_b = (alu_src) ? imm : reg_read2;

    // Write-Back MUX: Picks ALU Result OR RAM Data to save in Register
    assign final_write_data = (mem_read) ? ram_read_data : alu_result;

    // Next PC MUX: Standard +1 OR Jump/Branch Target
    wire take_branch = branch & alu_zero;
    assign next_pc_val = (jump | take_branch) ? imm : pc_plus_1;

    // ==========================================
    // 3. MODULE INSTANTIATIONS (The Chips)
    // ==========================================

    program_counter pc_inst (
        .clk(clk),
        .reset(reset),
        .next_pc(next_pc_val),
        .pc(pc_out)
    );

    instruction_memory inst_mem (
        .address(pc_out),
        .instruction(instruction)
    );

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

    register_file reg_file (
        .clk(clk),
        .we(reg_write),
        .rs1(rs1),
        .rs2(rs2),
        .rd(rd),
        .write_data(final_write_data), // From Write-Back MUX
        .read1(reg_read1),
        .read2(reg_read2)
    );

    alu main_alu (
        .A(reg_read1),
        .B(alu_in_b), // From ALU Source MUX
        .opcode(alu_ctrl),
        .result(alu_result),
        .zero(alu_zero)
    );

    data_memory d_mem (
        .clk(clk),
        .mem_read(mem_read),
        .mem_write(mem_write),
        .address(alu_result), // ALU calculates the address
        .write_data(reg_read2), // Data to save comes from RS2
        .read_data(ram_read_data)
    );

endmodule