# CPU Wiring & Connection Review

## Overview
Complete verification of all module instantiations, port connections, signal widths, and wiring across the 64-bit CPU design.

---

## 1. MODULE INTERFACE SUMMARY

### 1.1 Program Counter (`program_counter.v`)
**Parameters:** `PC_WIDTH` = 64

| Port | Direction | Width | Purpose |
|------|-----------|-------|---------|
| `clk` | Input | 1 | Clock input |
| `reset` | Input | 1 | Async reset (active high) |
| `next_pc` | Input | 64 | Next PC value from branch/jump logic |
| `pc` | Output | 64 | Current instruction address |

---

### 1.2 Instruction Memory (`instruction_memory.v`)
**Parameters:** `ROM_ADDR_WIDTH` = 10, `ILEN` = 32, `ADDR_W` = 64

| Port | Direction | Width | Purpose |
|------|-----------|-------|---------|
| `address` | Input | 64 | Architectural PC (byte address) |
| `instruction` | Output | 32 | Fetched 32-bit instruction |
| `instr_misaligned` | Output | 1 | Flag: instruction not 4-byte aligned |
| `instr_addr_oob` | Output | 1 | Flag: address out of ROM bounds |

**Memory Size:** 2^10 = 1024 bytes (256 × 32-bit instructions)

---

### 1.3 Immediate Generator (`imm_gen.v`)
**Parameters:** `XLEN` = 64, `ILEN` = 32

| Port | Direction | Width | Purpose |
|------|-----------|-------|---------|
| `instruction` | Input | 32 | Instruction to decode |
| `imm_out` | Output | 64 | Sign-extended immediate value |

**Supported Formats:** I-type, S-type, B-type, U-type, J-type

---

### 1.4 Control Unit (`control_unit.v`)
**Parameters:** None

| Port | Direction | Width | Purpose |
|------|-----------|-------|---------|
| `opcode` | Input | 7 | Instruction opcode [6:0] |
| `funct3` | Input | 3 | Instruction funct3 [14:12] |
| `funct7` | Input | 7 | Instruction funct7 [31:25] |
| `reg_write` | Output | 1 | Enable register write |
| `mem_read` | Output | 1 | Enable memory read |
| `mem_write` | Output | 1 | Enable memory write |
| `alu_src` | Output | 1 | ALU operand-B source (0=rs2, 1=imm) |
| `jump` | Output | 1 | JAL instruction flag |
| `jalr` | Output | 1 | JALR instruction flag |
| `branch` | Output | 1 | Branch instruction flag |
| `alu_a_sel` | Output | 2 | ALU operand-A source select |
| `wb_sel` | Output | 2 | Writeback source select |
| `alu_ctrl` | Output | 3 | ALU operation (funct3) |
| `funct7_out` | Output | 7 | ALU modifier (funct7) |
| `illegal_instr` | Output | 1 | Invalid instruction flag |
| `is_word_op` | Output | 1 | 32-bit word operation (RV64) |

---

### 1.5 Register File (`register_file.v`)
**Parameters:** `XLEN` = 64, `ADDR_WIDTH` = 5 (32 registers)

| Port | Direction | Width | Purpose |
|------|-----------|-------|---------|
| `clk` | Input | 1 | Clock input |
| `we` | Input | 1 | Write enable |
| `rs1` | Input | 5 | Read port 1 address |
| `rs2` | Input | 5 | Read port 2 address |
| `rd` | Input | 5 | Write port address |
| `write_data` | Input | 64 | Data to write |
| `read1` | Output | 64 | Read port 1 data |
| `read2` | Output | 64 | Read port 2 data |

**Notes:** x0 is hardwired to zero (reads return 0, writes ignored)

---

### 1.6 ALU (`alu.v`)
**Parameters:** `XLEN` = 64, `OP_WIDTH` = 3

| Port | Direction | Width | Purpose |
|------|-----------|-------|---------|
| `A` | Input | 64 | Operand A |
| `B` | Input | 64 | Operand B |
| `funct3` | Input | 3 | ALU function select (from control) |
| `funct7` | Input | 7 | ALU function modifier (from control) |
| `is_word_op` | Input | 1 | Flag: 32-bit word operation |
| `result` | Output | 64 | ALU result |
| `zero` | Output | 1 | Flag: result == 0 |
| `lt` | Output | 1 | Flag: signed(A) < signed(B) |
| `ltu` | Output | 1 | Flag: unsigned(A) < unsigned(B) |

**Operations:** ADD/SUB, SLL/SRL/SRA, AND/OR/XOR, SLT/SLTU, MUL, DIV (RV64M), REM

---

### 1.7 Data Memory (`data_memory.v`)
**Parameters:** `ADDR_WIDTH` = 8, `XLEN` = 64

| Port | Direction | Width | Purpose |
|------|-----------|-------|---------|
| `clk` | Input | 1 | Clock input |
| `mem_read` | Input | 1 | Read enable |
| `mem_write` | Input | 1 | Write enable |
| `funct3` | Input | 3 | Load/store width (LB/LH/LW/LD/SB/SH/SW/SD) |
| `address` | Input | 64 | Byte address (full 64-bit for bounds checking) |
| `write_data` | Input | 64 | Data to write |
| `read_data` | Output | 64 | Data read |
| `misaligned_access` | Output | 1 | Flag: address misaligned for funct3 |
| `illegal_funct3` | Output | 1 | Flag: unsupported funct3 |
| `addr_oob` | Output | 1 | Flag: address out of bounds |

**Memory Size:** 2^8 = 256 bytes

---

## 2. INSTANTIATION ANALYSIS

### 2.1 Program Counter Instantiation ✓
```verilog
program_counter #(.PC_WIDTH(ADDR_W)) pc_inst (
    .clk    (clk),           // ✓ System clock
    .reset  (reset),         // ✓ System reset
    .next_pc(next_pc_val),   // ✓ 64-bit (ADDR_W)
    .pc     (pc_out)         // ✓ 64-bit output
);
```
**Status:** ✓ **CORRECT**

---

### 2.2 Instruction Memory Instantiation ✓
```verilog
instruction_memory #(
    .ROM_ADDR_WIDTH(INST_ADDR_WIDTH),  // ✓ 10
    .ILEN           (ILEN),             // ✓ 32
    .ADDR_W         (ADDR_W)            // ✓ 64
) inst_mem (
    .address         (pc_out),              // ✓ 64-bit PC
    .instruction     (instruction),         // ✓ 32-bit instruction
    .instr_misaligned(instr_misaligned),    // ✓ Alignment flag
    .instr_addr_oob  (instr_addr_oob)      // ✓ Bounds check flag
);
```
**Status:** ✓ **CORRECT**

---

### 2.3 Immediate Generator Instantiation ✓
```verilog
imm_gen #(
    .XLEN(XLEN),    // ✓ 64
    .ILEN(ILEN)     // ✓ 32
) immediate_decoder (
    .instruction(instruction),   // ✓ 32-bit instruction from fetch
    .imm_out    (imm_ext)        // ✓ 64-bit sign-extended immediate
);
```
**Status:** ✓ **CORRECT**

---

### 2.4 Control Unit Instantiation ✓
```verilog
control_unit cu (
    .opcode       (opcode),           // ✓ instruction[6:0]
    .funct3       (funct3),           // ✓ instruction[14:12]
    .funct7       (funct7),           // ✓ instruction[31:25]
    .reg_write    (reg_write),        // ✓ 1-bit output
    .mem_read     (mem_read),         // ✓ 1-bit output
    .mem_write    (mem_write),        // ✓ 1-bit output
    .alu_src      (alu_src),          // ✓ 1-bit output
    .jump         (jump),             // ✓ 1-bit output
    .jalr         (jalr),             // ✓ 1-bit output
    .branch       (branch),           // ✓ 1-bit output
    .alu_a_sel    (alu_a_sel),        // ✓ 2-bit output
    .wb_sel       (wb_sel),           // ✓ 2-bit output
    .alu_ctrl     (alu_ctrl),         // ✓ 3-bit output (funct3)
    .funct7_out   (funct7_out),       // ✓ 7-bit output (funct7)
    .illegal_instr(illegal_instr),    // ✓ 1-bit output
    .is_word_op   (is_word_op)        // ✓ 1-bit output (RV64 word-width)
);
```
**Status:** ✓ **CORRECT**

---

### 2.5 Register File Instantiation ✓
```verilog
register_file #(
    .XLEN       (XLEN),      // ✓ 64
    .ADDR_WIDTH(5)           // ✓ 5 (32 registers)
) reg_file (
    .clk       (clk),                // ✓ System clock
    .we        (reg_write_safe),     // ✓ 1-bit safe write enable
    .rs1       (rs1),                // ✓ instruction[19:15]
    .rs2       (rs2),                // ✓ instruction[24:20]
    .rd        (rd),                 // ✓ instruction[11:7]
    .write_data(final_write_data),   // ✓ 64-bit MUX output
    .read1     (reg_read1),          // ✓ 64-bit output
    .read2     (reg_read2)           // ✓ 64-bit output
);
```
**Status:** ✓ **CORRECT**

---

### 2.6 ALU Instantiation ✓
```verilog
alu #(
    .XLEN      (XLEN),          // ✓ 64
    .OP_WIDTH  (3)              // ✓ 3 (funct3 width)
) main_alu (
    .A       (alu_in_a),        // ✓ 64-bit (from MUX: RS1/PC/ZERO)
    .B       (alu_in_b),        // ✓ 64-bit (from MUX: RS2/immediate)
    .funct3  (alu_ctrl),        // ✓ 3-bit (from control unit)
    .funct7  (funct7_out),      // ✓ 7-bit (from control unit)
    .is_word_op(is_word_op),    // ✓ 1-bit (from control unit)
    .result  (alu_result),      // ✓ 64-bit output
    .zero    (alu_zero),        // ✓ Comparison flag
    .lt      (alu_lt),          // ✓ Comparison flag
    .ltu     (alu_ltu)          // ✓ Comparison flag
);
```
**Status:** ✓ **CORRECT**

---

### 2.7 Data Memory Instantiation ✓
```verilog
data_memory #(
    .ADDR_WIDTH(DATA_ADDR_WIDTH),  // ✓ 8 (256 bytes)
    .XLEN(XLEN)                    // ✓ 64
) d_mem (
    .clk               (clk),                      // ✓ System clock
    .mem_read          (mem_read_safe && !is_mmio_addr),   // ✓ Conditional read
    .mem_write         (mem_write_safe && !is_mmio_addr),  // ✓ Conditional write
    .funct3            (funct3),                   // ✓ instruction[14:12]
    .address           (alu_result),              // ✓ 64-bit ALU output
    .write_data        (reg_read2),               // ✓ 64-bit RS2 value
    .read_data         (mem_read_data),           // ✓ 64-bit output
    .misaligned_access (data_misaligned),         // ✓ Alignment flag
    .illegal_funct3    (data_illegal_funct3),     // ✓ Funct3 validity flag
    .addr_oob          (data_addr_oob)            // ✓ Bounds check flag
);
```
**Status:** ✓ **CORRECT**

---

## 3. CRITICAL SIGNAL PATHS

### 3.1 Fetch Path: PC → IM → Instruction
```
pc_out (64)
    ↓
instruction_memory.address
    ↓
instruction_memory.instruction (32)
    ↓
instruction, opcode, funct3, funct7, rs1, rs2, rd
```
**Status:** ✓ **CORRECT**

---

### 3.2 Decode → Execute Path
```
instruction[31:25] → control_unit.funct7
instruction[14:12] → control_unit.funct3
instruction[6:0]   → control_unit.opcode
    ↓
control_unit outputs (reg_write, alu_src, alu_ctrl, funct7_out, etc.)
    ↓
rs1, rs2, rd → register_file.rs1/rs2/rd
    ↓
register_file.read1/read2 (64) → alu.A/B (via MUX)
```
**Status:** ✓ **CORRECT**

---

### 3.3 ALU → Memory Path
```
alu_result (64) → data_memory.address
reg_read2 (64)  → data_memory.write_data
    ↓
data_memory.read_data (64) → final_write_data (via MUX)
```
**Status:** ✓ **CORRECT**

---

### 3.4 Writeback Path
```
alu_result OR mem_read_data OR pc_plus_4
    ↓ (via wb_sel MUX)
final_write_data (64)
    ↓
register_file.write_data
    ↓
registers[rd] ← final_write_data (if we=1 and rd≠0)
```
**Status:** ✓ **CORRECT**

---

### 3.5 Branch/Jump Path
```
funct3 → branch_decision_logic
alu_zero, alu_lt, alu_ltu → branch_safe check
    ↓
next_pc_val selection:
  - jalr_safe? jalr_target : (jump_safe? jal_target : (take_branch? branch_target : pc_plus_4))
    ↓
program_counter.next_pc
```
**Status:** ✓ **CORRECT**

---

## 4. MULTIPLEXER LOGIC VERIFICATION

### 4.1 ALU Operand-A Selector (`alu_a_sel`)
```verilog
assign alu_in_a =
    (alu_a_sel == `ASEL_RS1)  ? reg_read1 :
    (alu_a_sel == `ASEL_PC)   ? pc_out    :
    (alu_a_sel == `ASEL_ZERO) ? {XLEN{1'b0}} :
                                reg_read1;
```
**Status:** ✓ **CORRECT** - All 64-bit sources, proper defaults

---

### 4.2 ALU Operand-B Selector (`alu_src`)
```verilog
assign alu_in_b = (alu_src) ? imm_ext : reg_read2;
```
**Status:** ✓ **CORRECT** - 64-bit immediate vs 64-bit RS2

---

### 4.3 Writeback Data Selector (`wb_sel`)
```verilog
assign final_write_data =
    (wb_sel == `WB_ALU) ? alu_result    :
    (wb_sel == `WB_MEM) ? mem_read_data :
    (wb_sel == `WB_PC4) ? pc_plus_4     :
                          alu_result;
```
**Status:** ✓ **CORRECT** - All 64-bit sources

---

### 4.4 Next PC Selector
```verilog
assign next_pc_val =
    (jalr_safe)   ? jalr_target   :
    (jump_safe)   ? jal_target    :
    (take_branch) ? branch_target :
                    pc_plus_4;
```
**Status:** ✓ **CORRECT** - All 64-bit paths, proper precedence

---

## 5. FAULT SUPPRESSION & CONTROL SIGNALS

### 5.1 Safe Write Enable Path
```verilog
assign reg_write_safe = reg_write && !core_fault;
assign mem_read_safe  = mem_read && !illegal_instr && !fetch_fault && 
                        !data_misaligned && !data_illegal_funct3 && !data_addr_oob;
assign mem_write_safe = mem_write && !illegal_instr && !fetch_fault && 
                        !data_misaligned && !data_illegal_funct3 && !data_addr_oob;
```
**Status:** ✓ **CORRECT** - Comprehensive fault suppression

---

### 5.2 Control Flow Safety
```verilog
assign jump_safe   = jump   && !core_fault;
assign jalr_safe   = jalr   && !core_fault;
assign branch_safe = branch && !core_fault;
```
**Status:** ✓ **CORRECT** - Prevents jumps on illegal instructions

---

## 6. TESTBENCH CONNECTIONS

### 6.1 DUT Instantiation in Testbench
```verilog
cpu_top uut (
    .clk(clk),           // ✓ Clock from testbench generator
    .reset(reset),       // ✓ Reset from testbench initial block
    .out_port(out_port)  // ✓ MMIO output (64-bit wire)
);
```
**Status:** ✓ **CORRECT**

### 6.2 Clock Generation
```verilog
localparam CLK_PERIOD_NS = 10;
always #(CLK_PERIOD_NS/2) clk = ~clk;  // 5ns pulse
```
**Status:** ✓ **CORRECT** - 100 MHz clock

---

## 7. PARAMETER PROPAGATION

| Parameter | Value | Used By | Purpose |
|-----------|-------|---------|---------|
| `XLEN` | 64 | PC, RegFile, ALU, Memories, ImmGen | Register/data width |
| `ILEN` | 32 | InstMem, ImmGen, Control | Instruction width |
| `ADDR_W` | 64 | PC, InstMem | Architectural address width |
| `INST_ADDR_WIDTH` | 10 | InstMem | Instruction memory size (1K bytes) |
| `DATA_ADDR_WIDTH` | 8 | DataMem | Data memory size (256 bytes) |
| `MMIO_ADDRESS` | 2^8-1 | CPU_TOP | MMIO detect (all 1s in low byte) |

**Status:** ✓ **ALL CORRECT**

---

## 8. MISSING OR UNUSED MODULES

### Modules Defined But Not Instantiated:
1. **`mux2x1.v`** - Generic 2-to-1 multiplexer
   - **Status:** NOT USED in cpu_top.v
   - **Note:** Multiplexing done inline with ternary operators
   
2. **`pre_decoder.v`** - Early instruction classifier
   - **Status:** NOT INSTANTIATED
   - **Note:** Optional microarchitectural feature, not needed for functional correctness

---

## 9. WIRING ISSUES FOUND

### ✓ NO CRITICAL ISSUES DETECTED

All port connections verified:
- ✓ All signal widths match
- ✓ All directions correct (input/output)
- ✓ All required ports connected
- ✓ No floating/unconnected signals
- ✓ No width mismatches
- ✓ Clock and reset properly distributed
- ✓ Fault suppression logic comprehensive

---

## 10. SUMMARY

### Connectivity Status: **PASS ✓**

**Total Modules:** 7 instantiated (2 defined but unused)

**Modules Verified:**
- ✓ program_counter
- ✓ instruction_memory
- ✓ imm_gen
- ✓ control_unit
- ✓ register_file
- ✓ alu
- ✓ data_memory

**Critical Paths Verified:**
- ✓ Fetch (PC → IM → Instruction)
- ✓ Decode (Instruction → Control → CU outputs)
- ✓ Execute (ALU with proper operands)
- ✓ Memory (Address, data read/write)
- ✓ Writeback (MUX selects correct data)
- ✓ Branch/Jump (Next PC calculation)

**Fault Suppression:** ✓ Comprehensive

**Testbench Integration:** ✓ Correct

---

## Recommendations

1. **`pre_decoder.v`** is defined but never used - can be safely removed if not needed for future enhancements
2. **`mux2x1.v`** is defined but not instantiated - not needed since multiplexing is done with ternary operators
3. **MMIO Logic** is correctly isolated from main memory writes (AND gate gates writes)
4. **Alignment checks** in data_memory.v correctly validate load/store operations
5. All register writes to x0 are properly suppressed

---

**Generated:** 2026-06-07  
**Design:** 64-bit CPU (RV64I + RV64M subset)  
**Verification:** Complete wiring and connection analysis
