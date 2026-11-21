# CPU Architecture: Module Interconnection Diagram

```
+----------------------------------------------------------------------------+
|                                FETCH STAGE                                 |
+----------------------------------------------------------------------------+
| Program Counter (64-bit)  ->  pc_out [64-bit]                              |
|         |                                                                  |
|         v                                                                  |
| Instruction Memory (ROM)  [ROM_ADDR_WIDTH = 10, 1KB]                       |
| Reads instruction at address pc_out                                        |
+----------------------------------------------------------------------------+
                        [instruction, 32-bit (ILEN=32)]
                                       |
                                       v
+----------------------------------------------------------------------------+
|                             INSTRUCTION DECODE                             |
+----------------------------------------------------------------------------+
| Fields: opcode[6:0]  funct3[2:0]  funct7[6:0]  rs1[4:0]  rs2[4:0]  rd[4:0] |
|                                                                            |
| Immediate Generator (ImmGen)  [XLEN=64]                                    |
|   Format: I / S / B / U / J decode                                         |
|   Output: imm_ext[63:0]                                                    |
|                                                                            |
| Control Unit (Combinational)                                               |
|   reg_write, mem_read, mem_write, alu_src, alu_a_sel,                      |
|   alu_ctrl[2:0], wb_sel, jump/jalr, branch,                                |
|   is_word_op, illegal_instr                                                |
+----------------------------------------------------------------------------+
                                [rs1, rs2, rd]
                                       |
                                       v
+----------------------------------------------------------------------------+
|                        REGISTER FILE (32 x 64-bit)                         |
+----------------------------------------------------------------------------+
| rs1[4:0]  ->  read1[63:0]                                                  |
| rs2[4:0]  ->  read2[63:0]                                                  |
| rd[4:0]   ->  write destination (write_data latched on clk)                |
| x0 hardwired to 0 (writes ignored)                                         |
+----------------------------------------------------------------------------+
                        [read1, read2, imm_ext, pc_out]
                                       |
                                       v
+----------------------------------------------------------------------------+
|                               EXECUTE STAGE                                |
+----------------------------------------------------------------------------+
| Operand-A Mux (alu_a_sel): ASEL_RS1 / ASEL_PC / ASEL_ZERO  ->  alu_in_a    |
| Operand-B Mux (alu_src):   0 = reg_read2 / 1 = imm_ext     ->  alu_in_b    |
|                                                                            |
| ALU (64-bit, RV64I + RV64M)                                                |
|   ADD / SUB / SHL / MUL / DIV / REM ...                                    |
|   outputs: result[63:0], zero, lt, ltu                                     |
|                                                                            |
| Branch Decision Logic                                                      |
|   BEQ:  zero      BNE:  !zero                                              |
|   BLT:  lt        BGE:  !lt                                                |
|   BLTU: ltu       BGEU: !ltu                                               |
|   take_branch = branch_safe && (condition met)                             |
+----------------------------------------------------------------------------+
                           [alu_result, take_branch]
                                       |
                                       v
+----------------------------------------------------------------------------+
|                               PC CALCULATION                               |
+----------------------------------------------------------------------------+
| 3-way Mux: JALR target / JAL target / Branch target / PC+4                 |
|   ->  next_pc_val  ->  fed back to Program Counter                         |
+----------------------------------------------------------------------------+
                           [alu_result (as address)]
                                       |
                                       v
+----------------------------------------------------------------------------+
|                     DATA MEMORY ACCESS (LOAD / STORE)                      |
+----------------------------------------------------------------------------+
| Address: alu_result[63:0]  (low 8 bits used, 256B memory)                  |
|                                                                            |
| Data Memory (256 bytes = 2^8)                                              |
|   funct3 selects: LB / LH / LW / LD / SB / SH / SW / SD                    |
|   write_data: reg_read2[63:0]                                              |
|   outputs: read_data[63:0], misaligned_access,                             |
|            illegal_funct3, addr_oob                                        |
|                                                                            |
| MMIO Check & Gating                                                        |
|   is_mmio_addr, is_mmio_write                                              |
|   out_port <- reg_read2 (if MMIO)                                          |
+----------------------------------------------------------------------------+
                                [mem_read_data]
                                       |
                                       v
+----------------------------------------------------------------------------+
|                              WRITEBACK STAGE                               |
+----------------------------------------------------------------------------+
| Writeback Mux (wb_sel)                                                     |
|   WB_ALU: alu_result[63:0]                                                 |
|   WB_MEM: mem_read_data[63:0]                                              |
|   WB_PC4: pc_plus_4[63:0]                                                  |
|   ->  final_write_data[63:0]                                               |
|                                                                            |
| Register Write-Back                                                        |
|   final_write_data -> reg_file (at rd)                                     |
|   reg_write_safe -> write enable                                           |
|   (x0 writes suppressed by reg_file)                                       |
+----------------------------------------------------------------------------+


+----------------------------------------------------------------------------+
|                             FAULT SUPPRESSION                              |
+----------------------------------------------------------------------------+
| fetch_fault = instr_misaligned || instr_addr_oob                           |
| mem_fault   = mem_op && (misaligned || illegal_funct3 || addr_oob)         |
| core_fault  = illegal_instr || fetch_fault || mem_fault                    |
| *_safe signals gate side effects on core_fault                             |
+----------------------------------------------------------------------------+
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

**Single Clock Domain:** All flip-flops use the same `clk`
- Program Counter (sequential)
- Register File write port (sequential)
- Data Memory write (synchronous)

**Combinational Logic:**
- All other paths are combinational (immediate response within the same cycle)