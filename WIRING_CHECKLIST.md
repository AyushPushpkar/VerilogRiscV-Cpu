# CPU Wiring Verification Checklist

## Quick Reference - Module Port Verification

### ✓ Program Counter
- [ ] `clk` (1-bit input) → System clock
- [ ] `reset` (1-bit input) → Async active-high
- [ ] `next_pc` (64-bit input) ← From PC calculation logic
- [ ] `pc` (64-bit output) → To instruction memory & branch calc
- [ ] **Parameter:** `PC_WIDTH` = 64

**Instantiation:** `program_counter #(.PC_WIDTH(ADDR_W)) pc_inst`
**Status:** ✓ CORRECT

---

### ✓ Instruction Memory
- [ ] `address` (64-bit input) ← From PC (pc_out)
- [ ] `instruction` (32-bit output) → To instruction decode & imm_gen
- [ ] `instr_misaligned` (1-bit output) → To fault logic
- [ ] `instr_addr_oob` (1-bit output) → To fault logic
- [ ] **Parameters:** `ROM_ADDR_WIDTH`=10, `ILEN`=32, `ADDR_W`=64
- [ ] **Memory Size:** 2^10 = 1024 bytes = 256 × 32-bit instructions
- [ ] **Init File:** `program.mem` (hex format)

**Instantiation:** `instruction_memory #(.ROM_ADDR_WIDTH(10), .ILEN(32), .ADDR_W(64))`
**Status:** ✓ CORRECT

---

### ✓ Immediate Generator
- [ ] `instruction` (32-bit input) ← From instruction_memory output
- [ ] `imm_out` (64-bit output) → To ALU (via alu_src mux) & target calc
- [ ] **Parameters:** `XLEN`=64, `ILEN`=32
- [ ] **Formats Decoded:** I, S, B, U, J types with proper sign extension

**Instantiation:** `imm_gen #(.XLEN(64), .ILEN(32)) immediate_decoder`
**Status:** ✓ CORRECT

---

### ✓ Control Unit
- [ ] `opcode` (7-bit input) ← instruction[6:0]
- [ ] `funct3` (3-bit input) ← instruction[14:12]
- [ ] `funct7` (7-bit input) ← instruction[31:25]
- [ ] **Outputs (all combinational):**
  - [ ] `reg_write` (1-bit) → RegFile write enable (before safety gating)
  - [ ] `mem_read` (1-bit) → DataMem read (before safety gating)
  - [ ] `mem_write` (1-bit) → DataMem write (before safety gating)
  - [ ] `alu_src` (1-bit) → Selects ALU operand B (RS2 vs immediate)
  - [ ] `jump` (1-bit) → JAL instruction detected
  - [ ] `jalr` (1-bit) → JALR instruction detected
  - [ ] `branch` (1-bit) → Branch instruction detected
  - [ ] `alu_a_sel` (2-bit) → Selects ALU operand A (RS1/PC/ZERO)
  - [ ] `wb_sel` (2-bit) → Selects writeback source (ALU/MEM/PC+4)
  - [ ] `alu_ctrl` (3-bit) → ALU operation (same as funct3)
  - [ ] `funct7_out` (7-bit) → ALU modifier (funct7)
  - [ ] `illegal_instr` (1-bit) → Invalid instruction flag
  - [ ] `is_word_op` (1-bit) → RV64 32-bit word operation flag

**Instantiation:** `control_unit cu`
**Status:** ✓ CORRECT

---

### ✓ Register File
- [ ] `clk` (1-bit input) → System clock (rising edge write)
- [ ] `we` (1-bit input) ← `reg_write_safe` (safety-gated)
- [ ] `rs1` (5-bit input) ← instruction[19:15]
- [ ] `rs2` (5-bit input) ← instruction[24:20]
- [ ] `rd` (5-bit input) ← instruction[11:7]
- [ ] `write_data` (64-bit input) ← `final_write_data` (from writeback mux)
- [ ] `read1` (64-bit output) → To ALU (via alu_a_sel mux)
- [ ] `read2` (64-bit output) → To ALU/DataMem (via alu_src mux & write_data path)
- [ ] **Parameters:** `XLEN`=64, `ADDR_WIDTH`=5
- [ ] **Registers:** x0-x31 (32 total, x0 always zero)
- [ ] **x0 Special Handling:** 
  - [ ] Reads from x0 return 0 (hardwired)
  - [ ] Writes to x0 are silently ignored

**Instantiation:** `register_file #(.XLEN(64), .ADDR_WIDTH(5)) reg_file`
**Status:** ✓ CORRECT

---

### ✓ ALU
- [ ] `A` (64-bit input) ← From `alu_in_a` (from alu_a_sel mux: RS1/PC/0)
- [ ] `B` (64-bit input) ← From `alu_in_b` (from alu_src mux: RS2/imm)
- [ ] `funct3` (3-bit input) ← `alu_ctrl` from control unit
- [ ] `funct7` (7-bit input) ← `funct7_out` from control unit
- [ ] `is_word_op` (1-bit input) ← From control unit (RV64 word ops)
- [ ] **Outputs:**
  - [ ] `result` (64-bit) → To ALU result register & writeback mux
  - [ ] `zero` (1-bit) → Flag: result == 0, used for branch decision
  - [ ] `lt` (1-bit) → Flag: signed(A) < signed(B), used for branch decision
  - [ ] `ltu` (1-bit) → Flag: unsigned(A) < unsigned(B), used for branch decision
- [ ] **Parameters:** `XLEN`=64, `OP_WIDTH`=3
- [ ] **Operations Supported:**
  - [ ] RV64I: ADD, SUB, SLL, SRL, SRA, AND, OR, XOR, SLT, SLTU
  - [ ] RV64 Word: ADDW, SUBW, SLLW, SRLW, SRAW, ADDIW, SLLIW, SRLIW, SRAIW
  - [ ] RV64M: MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU
  - [ ] Extensions: ANDN, ORN, XNOR, ROL, ROR

**Instantiation:** `alu #(.XLEN(64), .OP_WIDTH(3)) main_alu`
**Status:** ✓ CORRECT

---

### ✓ Data Memory
- [ ] `clk` (1-bit input) → System clock (synchronous write)
- [ ] `mem_read` (1-bit input) ← `mem_read_safe && !is_mmio_addr` (gated)
- [ ] `mem_write` (1-bit input) ← `mem_write_safe && !is_mmio_addr` (gated)
- [ ] `funct3` (3-bit input) ← instruction[14:12]
  - [ ] **Load operations:** LB (0), LH (1), LW (2), LD (3), LBU (4), LHU (5), LWU (6)
  - [ ] **Store operations:** SB (0), SH (1), SW (2), SD (3)
- [ ] `address` (64-bit input) ← `alu_result` (full for bounds checking, only low 8 bits used)
- [ ] `write_data` (64-bit input) ← `reg_read2` (from RS2)
- [ ] **Outputs:**
  - [ ] `read_data` (64-bit) → To writeback mux (when mem_read active)
  - [ ] `misaligned_access` (1-bit) → To fault logic (checked against funct3)
  - [ ] `illegal_funct3` (1-bit) → To fault logic (unsupported funct3 for load/store)
  - [ ] `addr_oob` (1-bit) → To fault logic (address beyond 256 bytes)
- [ ] **Parameters:** `ADDR_WIDTH`=8, `XLEN`=64
- [ ] **Memory Size:** 2^8 = 256 bytes
- [ ] **Init Value:** All bytes zeroed on startup
- [ ] **Alignment Checks:**
  - [ ] LB/LHU/SB: No alignment required
  - [ ] LH/LHU/SH: 2-byte aligned (address[0] must be 0)
  - [ ] LW/LWU/SW: 4-byte aligned (address[1:0] must be 0)
  - [ ] LD/SD: 8-byte aligned (address[2:0] must be 0)
- [ ] **MMIO Isolation:** Writes to address 0xFF (255) go to out_port, not RAM

**Instantiation:** `data_memory #(.ADDR_WIDTH(8), .XLEN(64)) d_mem`
**Status:** ✓ CORRECT

---

## Critical Signal Path Checklist

### Fetch Path
- [x] PC → InstructionMemory.address (64-bit)
- [x] InstructionMemory.instruction (32-bit) → Instruction decode & fields
- [x] Opcode/funct3/funct7/rs1/rs2/rd extracted correctly

### Decode Path
- [x] Opcode → ControlUnit.opcode
- [x] Funct3 → ControlUnit.funct3
- [x] Funct7 → ControlUnit.funct7
- [x] ControlUnit outputs (reg_write, mem_read, mem_write, alu_src, etc.)
- [x] Instruction → ImmGen → imm_ext (64-bit, sign-extended)

### Execute Path
- [x] rs1 → RegFile → read1 → (alu_a_sel mux) → alu.A
- [x] rs2 → RegFile → read2 → (alu_src mux) → alu.B
- [x] alu_a_sel selector (RS1/PC/ZERO) working correctly
- [x] alu_src selector (RS2/immediate) working correctly
- [x] alu_ctrl (funct3) → ALU operation
- [x] funct7_out → ALU modifier
- [x] is_word_op flag → ALU for RV64 word operations

### Branch/Jump Path
- [x] branch_safe = branch && !core_fault
- [x] jalr_safe = jalr && !core_fault
- [x] jump_safe = jump && !core_fault
- [x] funct3 → branch condition selection (BEQ/BNE/BLT/BGE/BLTU/BGEU)
- [x] alu_zero/lt/ltu → branch decision logic
- [x] branch_target = pc_out + imm_ext (for branches)
- [x] jal_target = pc_out + imm_ext (for jumps)
- [x] jalr_target = (rs1 + imm_ext) & ~1 (LSB cleared for alignment)
- [x] next_pc_val priority: jalr_safe > jump_safe > branch > pc+4
- [x] next_pc_val → PC.next_pc (64-bit)

### Memory Path
- [x] alu_result (64-bit address) → DataMem.address
- [x] mem_read_safe → DataMem.mem_read (with !is_mmio_addr gate)
- [x] mem_write_safe → DataMem.mem_write (with !is_mmio_addr gate)
- [x] funct3 → DataMem.funct3 (for load/store width)
- [x] reg_read2 → DataMem.write_data (store data)
- [x] DataMem.read_data (64-bit) → WriteMux (when mem_read)
- [x] DataMem.misaligned_access → fault logic
- [x] DataMem.illegal_funct3 → fault logic
- [x] DataMem.addr_oob → fault logic
- [x] is_mmio_addr gates memory operations (MMIO at address 0xFF)
- [x] is_mmio_write → out_port latch (reg_read2 on clock edge)

### Writeback Path
- [x] WriteMux selector: wb_sel (3 sources)
  - [x] WB_ALU: alu_result
  - [x] WB_MEM: mem_read_data
  - [x] WB_PC4: pc_plus_4
- [x] final_write_data (64-bit) → RegFile.write_data
- [x] rd (5-bit register address) → RegFile.rd
- [x] reg_write_safe (safety-gated) → RegFile.we
- [x] X0 writes suppressed by RegFile (hardwired architecture)

### Fault Suppression Path
- [x] instr_misaligned/instr_addr_oob → fetch_fault
- [x] data_misaligned/data_illegal_funct3/data_addr_oob → mem_fault (if mem_op)
- [x] illegal_instr OR fetch_fault OR mem_fault → core_fault
- [x] reg_write_safe = reg_write && !core_fault
- [x] mem_read_safe = mem_read && !(illegal_instr OR fetch_fault OR data_fault)
- [x] mem_write_safe = mem_write && !(illegal_instr OR fetch_fault OR data_fault)
- [x] jump_safe = jump && !core_fault
- [x] jalr_safe = jalr && !core_fault
- [x] branch_safe = branch && !core_fault

---

## Parameter Verification

| Parameter | Value | Used By | Notes |
|-----------|-------|---------|-------|
| `XLEN` | 64 | PC, RegFile, ALU, ImmGen, DataMem | Register/data/addr width |
| `ILEN` | 32 | InstMem, ImmGen, Control | Instruction width |
| `ADDR_W` | 64 | PC, InstMem | Architectural address width |
| `INST_ADDR_WIDTH` | 10 | InstMem | ROM size: 2^10 = 1K bytes |
| `DATA_ADDR_WIDTH` | 8 | DataMem | RAM size: 2^8 = 256 bytes |
| `MMIO_ADDRESS` | {8{1'b1}} | CPU_TOP | Address 0xFF detects MMIO |

**Consistency Check:** ✓ All parameters properly propagated

---

## Testbench Integration

### Testbench Instantiation
```verilog
cpu_top uut (
    .clk(clk),           // ✓ Clock from generator
    .reset(reset),       // ✓ Reset from initial block
    .out_port(out_port)  // ✓ MMIO output monitor
);
```

### Clock Generation
```verilog
localparam CLK_PERIOD_NS = 10;  // 100 MHz
always #(CLK_PERIOD_NS/2) clk = ~clk;
```
**Status:** ✓ Correct

### Reset Sequence
```verilog
reset = 1'b1;          // Assert reset
#(2 * CLK_PERIOD_NS);  // Hold for 2 cycles
reset = 1'b0;          // Release reset
```
**Status:** ✓ Correct

### Simulation Controls
- [ ] `$dumpfile("cpu_sim.vcd")` - Captures waveform
- [ ] `$dumpvars(0, tb_cpu)` - All signals logged
- [ ] Simulation timeout: MAX_CYCLES = 300
- [ ] Stuck PC detection: STUCK_PC_LIMIT = 15 cycles

---

## Unused Modules (Not Instantiated)

### mux2x1.v
- **Status:** Defined but not used
- **Reason:** Multiplexing done inline with ternary operators
- **Recommendation:** Can be safely removed

### pre_decoder.v
- **Status:** Defined but not instantiated
- **Reason:** Optional microarchitectural feature for future enhancements
- **Recommendation:** Can be safely removed or kept for future use

---

## Summary Scorecard

| Category | Status | Comments |
|----------|--------|----------|
| Module Port Matching | ✓ PASS | All 7 modules correctly instantiated |
| Signal Width Consistency | ✓ PASS | 64-bit paths properly aligned |
| Clock/Reset Distribution | ✓ PASS | All sequential modules clocked consistently |
| Multiplexer Logic | ✓ PASS | All operand selectors correct |
| Fault Suppression | ✓ PASS | Comprehensive error detection & suppression |
| Memory Isolation | ✓ PASS | MMIO properly gated from main RAM |
| Register Write Safety | ✓ PASS | x0 hardwired, all writes safety-gated |
| Testbench Connectivity | ✓ PASS | Correct clock generation & reset sequence |
| Parameter Propagation | ✓ PASS | All parameters correctly passed |
| **OVERALL** | **✓ PASS** | **No wiring issues detected** |

---

## Testing Notes

1. **Fetch Stage:** Verify PC increments (pc += 4) each cycle with no control flow
2. **Register Read:** Check that RS1 and RS2 correctly read register values
3. **ALU Operation:** Verify result matches expected operation
4. **Memory Access:** Check load/store operations with proper alignment
5. **Branch Decision:** Verify branch taken/not-taken based on condition
6. **Jump:** Verify PC jumps to JAL/JALR target
7. **Writeback:** Check register is updated with correct value after write enable
8. **Fault Handling:** Verify misaligned/illegal operations suppress side effects
9. **MMIO:** Check out_port captures correct value on MMIO write

---

Generated: 2026-06-07
