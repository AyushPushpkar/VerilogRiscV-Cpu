# 8-bit Single-Cycle RISC CPU

A Verilog implementation of an 8-bit RISC CPU with Harvard architecture, 32-bit instructions, and single-cycle execution.

## Specifications

| Feature | Value |
|---------|-------|
| Data Width | 8 bits |
| Instruction Width | 32 bits |
| Registers | 8 general-purpose (R0-R7) |
| Instruction Memory | 256 × 32-bit (ROM) |
| Data Memory | 256 × 8-bit (RAM) |
| Architecture | Harvard (separate I/D memory) |
| Execution Model | Single-cycle |

## Instruction Set

| Opcode | Operation | Function Codes |
|--------|-----------|----------------|
| 0x0 (MATH) | Register operations | ADD, SUB, AND, OR, XOR, SLL, SRL, SRA, SLT, SLTU |
| 0x5 (MOV) | Move immediate | - |
| 0x6 (LOAD) | Load from memory | - |
| 0x7 (STORE) | Store to memory | - |
| 0x8 (JMP) | Unconditional jump | - |
| 0x9 (BEQ) | Branch if equal | - |

## Core Modules

| Module | Function |
|--------|----------|
| `cpu_top.v` | Top-level integration & datapath |
| `control_unit.v` | Instruction decoding & control signals |
| `alu.v` | 11 arithmetic/logic operations |
| `register_file.v` | Dual-read, single-write registers |
| `program_counter.v` | Instruction address (8-bit) |
| `instruction_memory.v` | Instruction ROM loads from `program.mem` |
| `data_memory.v` | Data RAM for load/store operations |
| `mux2x1.v` | Generic 2-to-1 multiplexer |
| `defines.v` | Opcode & function code constants |

## Running Simulation

### Using run.bat (Recommended)
```cmd
cd C:\Users\ayush\OneDrive\Desktop\8bitcpu
run.bat
```

### Manual Compilation
```cmd
iverilog -I src/ -o cpu_sim src/*.v tb/*.v
vvp cpu_sim
gtkwave cpu_sim.vcd
```

Output waveform: `cpu_sim.vcd` (viewed with GTKWave)