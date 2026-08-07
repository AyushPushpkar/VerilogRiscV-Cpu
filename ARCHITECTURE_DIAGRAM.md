# CPU Architecture: Module Interconnection Diagram

```
                        ┌─────────────────────────────────────────────┐
                        │           CPU FETCH STAGE                   │
                        │                                             │
              ┌────────►│  Program Counter (64-bit)  pc_out ┌─────────│
              │         │  [Updates on clk/reset]           │ADDR_W=64|
              │         └───────────────────────────────────│         │
              │                      │                      └─────────┘
              │                      │                            │
              │            ┌─────────▼──────────────────────┐     │
              │            │                                │     │
              │            │  Instruction Memory (ROM)      │     │
              │            │  ROM_ADDR_WIDTH = 10 (1K B)    │     │
              │            │  Reads instruction @ address ◄─┼─────┘
              │            │                                │
              │            └──────────────┬──────────────────┘
              │                           │
              │      ┌────────────────────┼────────────────────┐
              │      │                    │                    │
              │      │         [ILEN=32 bits]                  │
              │      │                    │                    │
              │      ▼                    ▼                    ▼
        ┌──────────────────┬──────────────────────────────────────────┐
        │   INSTRUCTION    │  Immediate Generator (ImmGen)   [XLEN=64]│
        │   DECODE         │                                           │
        │  ┌─────────────┐  │  ┌─────────────────────────────────────┐ │
        │  │ opcode[6:0] │──┼─►│ instruction[31:0]                   │ │
        │  │ funct3[2:0] │──┼─►│ Format: I/S/B/U/J decode           │ │
        │  │ funct7[6:0] │──┼─►│ Output: imm_ext[XLEN-1:0] ────────┐│ │
        │  │ rs1[4:0]    │──┼─┐│                                      ││ │
        │  │ rs2[4:0]    │──┼─┤└──────────────────────────────────────┘│ │
        │  │ rd[4:0]     │──┼─┘                                        │ │
        │  └─────────────┘  │                                         │ │
        │        │          └─────────────────────────────────────────┘ │
        │        │                                                      │
        │        ▼                                                      │
        │   ┌──────────────────┐                                        │
        │   │  Control Unit    │                                        │
        │   │  (Combinational) │                                        │
        │   │                  │                                        │
        │   │ Output:          │                                        │
        │   │ - reg_write      │                                        │
        │   │ - mem_read       │                                        │
        │   │ - mem_write      │                                        │
        │   │ - alu_src (I/Imm)│                                        │
        │   │ - alu_a_sel      │  ┌──────────────────────────┐         │
        │   │ - alu_ctrl[2:0]  │  │ (funct3)                 │         │
        │   │ - funct7_out[6:0]│  │ (funct7)                 │         │
        │   │ - wb_sel         │  │ - is_word_op             │         │
        │   │ - jump/jalr      │  │                          │         │
        │   │ - branch         │  └──────────────────────────┘         │
        │   │ - is_word_op     │                                        │
        │   │ - illegal_instr  │                                        │
        │   └──────────────────┘                                        │
        └──────────────────────────────────────────────────────────────┘
                  │                          │
                  ▼                          ▼
        ┌────────────────────────────────────────────────────┐
        │        REGISTER FILE (32 × 64-bit)                 │
        │  [Read-only on this cycle, Write on clk edge]      │
        │                                                    │
        │  rs1[4:0] ──►  read1[XLEN-1:0] ─────────┐        │
        │                                          │        │
        │  rs2[4:0] ──►  read2[XLEN-1:0] ─────────┤        │
        │                                          │        │
        │  rd[4:0]  ──►  (write destination)      │        │
        │  write_data    (latched on clk)         │        │
        │                                          ▼        │
        │  x0 = 0 (hardwired, writes ignored)     │        │
        └────────────────────────────────────────┼─────────┘
                                                  │
        ┌─────────────────────────────────────────┴──────────────────┐
        │                   EXECUTE STAGE                            │
        │                                                             │
        │  ┌──────────────────────────────────────────────────┐      │
        │  │ Operand-A Multiplexer (alu_a_sel)               │      │
        │  │                                                   │      │
        │  │  [ASEL_RS1]  ──┐                                 │      │
        │  │  [ASEL_PC]   ──├─► alu_in_a[63:0] ─────┐       │      │
        │  │  [ASEL_ZERO] ──┘                        │       │      │
        │  └──────────────────────────────────────────┼───────┘      │
        │                                             │               │
        │  ┌──────────────────────────────────────────┼───────┐      │
        │  │ Operand-B Multiplexer (alu_src)         │       │      │
        │  │                                          │       │      │
        │  │  [0: reg_read2] ─┐                      │       │      │
        │  │  [1: imm_ext] ───┼─► alu_in_b[63:0] ─┐ │       │      │
        │  │                  └──────────────────┐ │ │       │      │
        │  └────────────────────────────────────┼─┼─┘       │      │
        │                                        │ │         │      │
        │  ┌──────────────────────────────────────┼─┼─────┐  │      │
        │  │ ALU (64-bit, RV64I + RV64M)         │ │     │  │      │
        │  │                                      │ │     │  │      │
        │  │  A[63:0] ──────────►├─────┐         │ │     │  │      │
        │  │                      │ ADD │         │ │     │  │      │
        │  │  B[63:0] ──────────►├─SUB │─► result[63:0] │  │      │
        │  │                      │ ... │  (→ final_wr)  │  │      │
        │  │  funct3[2:0] ──────►├─SHL │  zero     │    │  │      │
        │  │  funct7[6:0] ──────►├─MUL │  lt ─────┐│    │  │      │
        │  │  is_word_op ────────│ DIV │  ltu ───┐││    │  │      │
        │  │                      │ REM │         │││    │  │      │
        │  │                      └─────┘         │││    │  │      │
        │  └────────────────────────────────────┼─┼┼────┼──┘      │
        │                                        │ │││    │         │
        │        ┌────────────────────────────┐  │ │││    │         │
        │        │ Branch Decision Logic      │  │ │││    │         │
        │        │                            │  │ │││    │         │
        │        │ BEQ: alu_zero              │  │ │││    │         │
        │        │ BNE: !alu_zero            │  │ │││    │         │
        │        │ BLT: alu_lt               │  │ │││    │         │
        │        │ BGE: !alu_lt              │  │ │││    │         │
        │        │ BLTU: alu_ltu             │  │ │││    │         │
        │        │ BGEU: !alu_ltu            │  │ │││    │         │
        │        │                            │  │ │││    │         │
        │        └────────────────────────────┘  │ │││    │         │
        │                  │                     │ │││    │         │
        │                  ▼                     │ │││    │         │
        │        take_branch = branch_safe &&   │ │││    │         │
        │                   (condition met)      │ │││    │         │
        └────────────────────┬──────────────────┼─┼┼┼────┼─────────┘
                             │                  │ │││    │
        ┌────────────────────┼──────────────────┼─┼┼┼────┼──────────┐
        │  PC CALCULATION                       │ │││    │          │
        │                                        │ │││    │          │
        │  next_pc_val ◄─┐                      │ │││    │          │
        │                │ (pc_plus_4)          │ │││    │          │
        │  ┌─────────────┼────────────────────┐ │ │││    │          │
        │  │             │ jalr_target        ├─┴─────┐  │          │
        │  │ ┌───────────┼───────────────────┐│ │││    │          │
        │  │ │           │ jal_target        ││ │││    │          │
        │  │ │ ┌─────────┼──────────────────┐││ │││    │          │
        │  │ │ │          │ branch_target    │││ │││    │          │
        │  │ │ │          │                  │││ │││    │          │
        │  │ │ │  ┌──────►├──────┐          │││ │││    │          │
        │  │ │ │  │  MUX  │ JALR?├─────────►││ │││    │          │
        │  │ │ │  │  (3-  │ JUMP?├─────────►││ │││    │          │
        │  │ │ │  │  way) │ BRANCH?         │││ │││    │          │
        │  │ │ │  │       │ PC+4            │││ │││    │          │
        │  │ │ │  └──────►└──────┘          │││ │││    │          │
        │  │ │ │                             │││ │││    │          │
        │  │ │ └─────────────────────────────┘││ │││    │          │
        │  │ │                                 ││ │││    │          │
        │  │ └─────────────────────────────────┘│ │││    │          │
        │  └───────────────────────────────────┬┘ │││    │          │
        │                                       ▼ │││    │          │
        │                                    next_pc
        │                                    (to PC)    │          │
        └───────────────────────────────────────┬──────┘          │
                                                                    │
        ┌───────────────────────────────────────────────────────┐ │
        │  DATA MEMORY ACCESS (LOAD/STORE)                      │ │
        │                                                        │ │
        │  Address: alu_result[63:0] ◄────────────────────────┐ │ │
        │  (only low 8 bits used for 256B memory)            │ │ │
        │                                                    │ │ │
        │  ┌──────────────────────────────────────────────────┼─┘ │
        │  │ Data Memory (256 bytes = 2^8)                   │   │
        │  │                                                  │   │
        │  │ mem_read[1-bit] ◄────────────────────────────┐  │   │
        │  │ mem_write[1-bit] ◄───────────────────────────┼──┤   │
        │  │ funct3[2:0] ◄──────────────────────────────┐ │  │   │
        │  │  (LB/LH/LW/LD/SB/SH/SW/SD)                │ │  │   │
        │  │                                            │ │  │   │
        │  │ write_data: reg_read2[63:0] ◄──────────┐  │ │  │   │
        │  │                                        │  │ │  │   │
        │  │ Outputs:                              │  │ │  │   │
        │  │  read_data[63:0] ────────────────┐    │  │ │  │   │
        │  │  misaligned_access               │    │  │ │  │   │
        │  │  illegal_funct3                  │    │  │ │  │   │
        │  │  addr_oob                        │    │  │ │  │   │
        │  │                                   │    │  │ │  │   │
        │  └────────────────────────────────────┼────┼──┼──┼──┘   │
        │                                        │    │  │  │     │
        │  ┌────────────────────────────────────┴────┼──┘  │     │
        │  │ MMIO Check & Gating               │  │  │     │     │
        │  │ is_mmio_addr = (alu_result_low ==  │  │  │     │     │
        │  │                 {DATA_ADDR_W{1}}   │  │  │     │     │
        │  │ is_mmio_write = mem_write_safe &&  │  │  │     │     │
        │  │                is_mmio_addr        │  │  │     │     │
        │  │                                    │  │  │     │     │
        │  │ out_port ◄─ reg_read2 (if MMIO)   │  │  │     │     │
        │  │                                    │  │  │     │     │
        │  └────────────────────────────────────┼──┼──┼─────┘     │
        │                                        │  │  │           │
        └────────────────────────────────────────┼──┼──┘───────────┘
                                                 │  │
        ┌────────────────────────────────────────┼──┘────────────────┐
        │           WRITEBACK STAGE              │                   │
        │                                        ▼                   │
        │  ┌───────────────────────────────────────────────┐         │
        │  │ Writeback Multiplexer (wb_sel)                │         │
        │  │                                                │         │
        │  │  [WB_ALU]  alu_result[63:0]           ───┐    │         │
        │  │  [WB_MEM]  mem_read_data[63:0]       ────┤──┬┐┐         │
        │  │  [WB_PC4]  pc_plus_4[63:0]          ─────┤──┤││         │
        │  │                                           │  │││         │
        │  │  MUX Output: final_write_data[63:0] ◄────┼──┘││         │
        │  └─────────────────────────────────────────┼────┼┘         │
        │                                             │    │          │
        │  ┌──────────────────────────────────────────┼────┘          │
        │  │ Register Write-Back                      │              │
        │  │                                          │              │
        │  │  final_write_data[63:0] ──► reg_file    │              │
        │  │  rd[4:0] ──► reg_file.rd               │              │
        │  │  reg_write_safe ──► write enable        │              │
        │  │                                          │              │
        │  │  (x0 writes suppressed by reg_file)     │              │
        │  └──────────────────────────────────────────┘              │
        │                                                             │
        └─────────────────────────────────────────────────────────────┘

                              ┌──────────────────────┐
                              │   FAULT SUPPRESSION   │
                              │                       │
                              │ fetch_fault =        │
                              │   instr_misaligned || │
                              │   instr_addr_oob     │
                              │                       │
                              │ mem_fault =          │
                              │   (mem_op) &&        │
                              │   (misaligned ||     │
                              │    illegal_funct3 || │
                              │    addr_oob)         │
                              │                       │
                              │ core_fault =         │
                              │   illegal_instr ||   │
                              │   fetch_fault ||     │
                              │   mem_fault          │
                              │                       │
                              │ *_safe signals gate  │
                              │ side effects on      │
                              │ core_fault           │
                              └──────────────────────┘
```

## Signal Summary Table

| Signal | Width | Source | Destination | Purpose |
|--------|-------|--------|-------------|---------|
| `clk` | 1 | Testbench | All sequential modules | Clock |
| `reset` | 1 | Testbench | All sequential modules | Async reset |
| `pc_out` | 64 | PC | InstMem, target calc | Current instruction address |
| `instruction` | 32 | InstMem | CU, ImmGen, DecodeLogic | Fetched instruction |
| `imm_ext` | 64 | ImmGen | ALU (via mux), target calc | Sign-extended immediate |
| `reg_read1/2` | 64 | RegFile | ALU (via mux) | Register values |
| `alu_result` | 64 | ALU | DataMem addr, WriteMux | ALU output |
| `alu_zero/lt/ltu` | 3 | ALU | Branch logic | Comparison flags |
| `mem_read_data` | 64 | DataMem | WriteMux | Loaded data |
| `final_write_data` | 64 | WriteMux | RegFile | Writeback data |
| `next_pc_val` | 64 | PCCalc | PC (next_pc input) | Next instruction address |
| `reg_write_safe` | 1 | FaultLogic | RegFile (we) | Safe write enable |
| `mem_read_safe` | 1 | FaultLogic | DataMem | Safe read enable |
| `mem_write_safe` | 1 | FaultLogic | DataMem | Safe write enable |

## Clock Domains

**Single Clock Domain:** All flip-flops use same `clk`
- Program Counter (sequential)
- Register File write port (sequential)
- Data Memory write (synchronous)

**Combinational Logic:**
- All other paths are combinational (immediate response within same cycle)
