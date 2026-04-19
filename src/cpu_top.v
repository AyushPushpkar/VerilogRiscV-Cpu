//================================================================================
// CPU Top Level - RV32I + RV32M (Single-Cycle, Tightened and Extended)
//================================================================================
// Single-cycle 32-bit RISC-V style CPU with:
//   - 32-bit architectural PC
//   - RV32I-style integer datapath
//   - RV32M ALU support
//   - Full RV32I load/store width support:
//       LB, LH, LW, LBU, LHU
//       SB, SH, SW
//   - JAL and JALR support
//   - Full branch family:
//       BEQ, BNE, BLT, BGE, BLTU, BGEU
//   - LUI and AUIPC with clean operand-A selection
//   - MMIO output support
//   - Illegal instruction / misalignment / address fault visibility
//
// DESIGN NOTES:
//   - Architectural PC is 32-bit
//   - Local memories may still be much smaller and use low address bits only
//   - This design detects illegal / misaligned / out-of-range conditions and
//     suppresses architectural side effects safely, but does not implement a
//     trap system
//================================================================================

`timescale 1ns/1ns
`include "defines.v"

module cpu_top #(
    parameter DATA_WIDTH      = 32,
    parameter PC_WIDTH        = 32,
    parameter INST_ADDR_WIDTH = 10,
    parameter DATA_ADDR_WIDTH = 8,
    parameter MMIO_ADDRESS    = {DATA_ADDR_WIDTH{1'b1}}
)(
    input  clk,
    input  reset,
    output reg [DATA_WIDTH-1:0] out_port
);

    //========================================================================
    // 1. FETCH STAGE SIGNALS
    //========================================================================
    wire [PC_WIDTH-1:0] pc_out;
    wire [PC_WIDTH-1:0] pc_plus_4;
    wire [PC_WIDTH-1:0] next_pc_val;

    wire [31:0] instruction;
    wire        instr_misaligned;
    wire        instr_addr_oob;

    assign pc_plus_4 = pc_out + 32'd4;

    //========================================================================
    // 2. DECODE FIELDS
    //========================================================================
    wire [6:0] opcode = instruction[6:0];
    wire [4:0] rd     = instruction[11:7];
    wire [2:0] funct3 = instruction[14:12];
    wire [4:0] rs1    = instruction[19:15];
    wire [4:0] rs2    = instruction[24:20];
    wire [6:0] funct7 = instruction[31:25];

    wire [31:0] imm32;

    //========================================================================
    // 3. CONTROL SIGNALS
    //========================================================================
    wire        reg_write;
    wire        mem_read;
    wire        mem_write;
    wire        alu_src;
    wire        jump;
    wire        jalr;
    wire        branch;
    wire [1:0]  alu_a_sel;
    wire [1:0]  wb_sel;
    wire [2:0]  alu_ctrl;
    wire [6:0]  funct7_out;
    wire        illegal_instr;

    //========================================================================
    // 4. REGISTER FILE + ALU SIGNALS
    //========================================================================
    wire [DATA_WIDTH-1:0] reg_read1;
    wire [DATA_WIDTH-1:0] reg_read2;

    wire [DATA_WIDTH-1:0] alu_in_a;
    wire [DATA_WIDTH-1:0] alu_in_b;
    wire [DATA_WIDTH-1:0] alu_result;

    wire alu_zero;
    wire alu_lt;
    wire alu_ltu;

    //========================================================================
    // 5. MEMORY / WRITEBACK SIGNALS
    //========================================================================
    wire [DATA_WIDTH-1:0] mem_read_data;
    wire                  data_misaligned;
    wire                  data_illegal_funct3;
    wire                  data_addr_oob;

    wire [DATA_WIDTH-1:0] final_write_data;

    //========================================================================
    // 6. INTERNAL FAULT / SUPPRESSION SIGNALS
    //========================================================================
    wire fetch_fault;
    wire mem_fault;
    wire core_fault;

    wire reg_write_safe;
    wire mem_read_safe;
    wire mem_write_safe;
    wire jump_safe;
    wire jalr_safe;
    wire branch_safe;

    //========================================================================
    // 7. TARGET ADDRESS / BRANCH LOGIC
    //========================================================================
    wire take_branch;

    wire [PC_WIDTH-1:0] branch_target;
    wire [PC_WIDTH-1:0] jal_target;
    wire [PC_WIDTH-1:0] jalr_target;

    //========================================================================
    // 8. MMIO SIGNALS
    //========================================================================
    wire is_mmio_addr;
    wire is_mmio_write;

    //========================================================================
    // 9. FETCH FAULT / MEMORY FAULT AGGREGATION
    //========================================================================
    assign fetch_fault = instr_misaligned || instr_addr_oob;

    assign mem_fault =
        ((mem_read || mem_write) &&
         (data_misaligned || data_illegal_funct3 || data_addr_oob));

    assign core_fault = illegal_instr || fetch_fault || mem_fault;

    // Suppress side effects on invalid instructions / invalid accesses
    assign reg_write_safe = reg_write && !core_fault;

    assign mem_read_safe  = mem_read  && !illegal_instr && !fetch_fault &&
                            !data_misaligned && !data_illegal_funct3 &&
                            !data_addr_oob;

    assign mem_write_safe = mem_write && !illegal_instr && !fetch_fault &&
                            !data_misaligned && !data_illegal_funct3 &&
                            !data_addr_oob;

    assign jump_safe   = jump   && !core_fault;
    assign jalr_safe   = jalr   && !core_fault;
    assign branch_safe = branch && !core_fault;

    //========================================================================
    // 10. ALU OPERAND SELECT
    //========================================================================
    assign alu_in_a =
        (alu_a_sel == `ASEL_RS1)  ? reg_read1 :
        (alu_a_sel == `ASEL_PC)   ? pc_out    :
        (alu_a_sel == `ASEL_ZERO) ? {DATA_WIDTH{1'b0}} :
                                    reg_read1;

    assign alu_in_b = (alu_src) ? imm32 : reg_read2;

    //========================================================================
    // 11. BRANCH DECISION LOGIC
    //========================================================================
    assign take_branch =
        branch_safe && (
            (funct3 == `BR_BEQ  &&  alu_zero) ||
            (funct3 == `BR_BNE  && !alu_zero) ||
            (funct3 == `BR_BLT  &&  alu_lt)   ||
            (funct3 == `BR_BGE  && !alu_lt)   ||
            (funct3 == `BR_BLTU &&  alu_ltu)  ||
            (funct3 == `BR_BGEU && !alu_ltu)
        );

    //========================================================================
    // 12. 32-BIT TARGET ADDRESS FORMATION
    //========================================================================
    // All control-flow targets are computed in architectural 32-bit space.
    // Truncation, if any, happens only when smaller local memories use low bits.
    assign branch_target = pc_out + imm32;
    assign jal_target    = pc_out + imm32;
    assign jalr_target   = (reg_read1 + imm32) & ~32'd1;

    assign next_pc_val =
        (jalr_safe)   ? jalr_target   :
        (jump_safe)   ? jal_target    :
        (take_branch) ? branch_target :
                        pc_plus_4;

    //========================================================================
    // 13. WRITE-BACK SELECTION
    //========================================================================
    assign final_write_data =
        (wb_sel == `WB_ALU) ? alu_result    :
        (wb_sel == `WB_MEM) ? mem_read_data :
        (wb_sel == `WB_PC4) ? pc_plus_4     :
                              alu_result;

    //========================================================================
    // 14. MMIO LOGIC
    //========================================================================
    // MMIO is treated as a store destination outside normal RAM.
    assign is_mmio_addr  = (alu_result[DATA_ADDR_WIDTH-1:0] == MMIO_ADDRESS);
    assign is_mmio_write = mem_write_safe && is_mmio_addr;

    always @(posedge clk or posedge reset) begin
        if (reset)
            out_port <= {DATA_WIDTH{1'b0}};
        else if (is_mmio_write)
            out_port <= reg_read2;
    end

    //========================================================================
    // 15. MODULE INSTANTIATIONS
    //========================================================================

    //------------------------------------------------------------------------
    // Program Counter
    //------------------------------------------------------------------------
    program_counter #(
        .PC_WIDTH(PC_WIDTH)
    ) pc_inst (
        .clk    (clk),
        .reset  (reset),
        .next_pc(next_pc_val),
        .pc     (pc_out)
    );

    //------------------------------------------------------------------------
    // Instruction Memory
    //------------------------------------------------------------------------
    instruction_memory #(
        .ADDR_WIDTH(INST_ADDR_WIDTH),
        .INST_WIDTH(32),
        .PC_WIDTH  (PC_WIDTH)
    ) inst_mem (
        .address         (pc_out),
        .instruction     (instruction),
        .instr_misaligned(instr_misaligned),
        .instr_addr_oob  (instr_addr_oob)
    );

    //------------------------------------------------------------------------
    // Immediate Generator
    //------------------------------------------------------------------------
    imm_gen immediate_decoder (
        .instruction(instruction),
        .imm_out    (imm32)
    );

    //------------------------------------------------------------------------
    // Control Unit
    //------------------------------------------------------------------------
    control_unit cu (
        .opcode       (opcode),
        .funct3       (funct3),
        .funct7       (funct7),

        .reg_write    (reg_write),
        .mem_read     (mem_read),
        .mem_write    (mem_write),
        .alu_src      (alu_src),
        .jump         (jump),
        .jalr         (jalr),
        .branch       (branch),
        .alu_a_sel    (alu_a_sel),
        .wb_sel       (wb_sel),
        .alu_ctrl     (alu_ctrl),
        .funct7_out   (funct7_out),
        .illegal_instr(illegal_instr)
    );

    //------------------------------------------------------------------------
    // Register File
    //------------------------------------------------------------------------
    register_file #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(5)
    ) reg_file (
        .clk       (clk),
        .we        (reg_write_safe),
        .rs1       (rs1),
        .rs2       (rs2),
        .rd        (rd),
        .write_data(final_write_data),
        .read1     (reg_read1),
        .read2     (reg_read2)
    );

    //------------------------------------------------------------------------
    // ALU
    //------------------------------------------------------------------------
    alu #(
        .DATA_WIDTH(DATA_WIDTH),
        .OP_WIDTH  (3)
    ) main_alu (
        .A      (alu_in_a),
        .B      (alu_in_b),
        .funct3 (alu_ctrl),
        .funct7 (funct7_out),
        .result (alu_result),
        .zero   (alu_zero),
        .lt     (alu_lt),
        .ltu    (alu_ltu)
    );

    //------------------------------------------------------------------------
    // Data Memory
    //------------------------------------------------------------------------
    // Normal RAM writes are suppressed for MMIO destinations.
    data_memory #(
        .ADDR_WIDTH(DATA_ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) d_mem (
        .clk               (clk),
        .mem_read          (mem_read_safe && !is_mmio_addr),
        .mem_write         (mem_write_safe && !is_mmio_addr),
        .funct3            (funct3),
        .address           (alu_result[DATA_ADDR_WIDTH-1:0]),
        .write_data        (reg_read2),
        .read_data         (mem_read_data),
        .misaligned_access (data_misaligned),
        .illegal_funct3    (data_illegal_funct3),
        .addr_oob          (data_addr_oob)
    );

endmodule