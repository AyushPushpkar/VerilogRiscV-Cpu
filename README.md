# VerilogRiscV-Cpu
# 8-Bit CPU Simulation

A simple 8-bit RISC processor implementation in Verilog with Harvard architecture.

## Prerequisites

The following tools are required:

1. **Icarus Verilog** - Verilog compiler and simulator ✓ *Already installed*
2. **GTKWave** - Waveform viewer ✓ *Already installed*

You're all set to run the simulation!

## CPU Specifications

- **Data Width**: 8 bits
- **Address Space**: 256 locations (instruction and data)
- **Registers**: 8 general-purpose registers
- **Instruction Width**: 16 bits
- **Architecture**: Harvard (separate instruction and data memory)

## Instruction Set

| Opcode | Instruction | Description |
|--------|-------------|-------------|
| 0000   | ADD         | Register addition |
| 0001   | SUB         | Register subtraction |
| 0010   | AND         | Bitwise AND |
| 0011   | OR          | Bitwise OR |
| 0100   | XOR         | Bitwise XOR |
| 0101   | MOV         | Move immediate to register |
| 0110   | LOAD        | Load from memory |
| 0111   | STORE       | Store to memory |
| 1000   | JMP         | Unconditional jump |

## Quick Start - Command Prompt

### Basic CPU Test
```cmd
cd "C:\Users\ayush\OneDrive\Desktop\8bitcpu"
iverilog -o cpu_sim src\*.v tb\cpu_tb.v
vvp cpu_sim
gtkwave cpu.vcd
```

### Comprehensive Test Suite
```cmd
cd "C:\Users\ayush\OneDrive\Desktop\8bitcpu"
iverilog -o comprehensive_sim src\*.v tb\comprehensive_tb.v
vvp comprehensive_sim
gtkwave comprehensive_test.vcd
```

## Simulation Categories

### 🎮 User Interactive Simulations

#### 1. Interactive CPU Simulator  
Simulates step-by-step user interaction with the CPU:
```cmd
iverilog -o interactive_sim src\*.v tb\interactive_tb.v
vvp interactive_sim
gtkwave interactive_cpu.vcd
```
**Features:**
- Manual program loading simulation
- Step-by-step execution like a debugger  
- Real-time state monitoring
- User-controlled program flow

#### 2. Real-Time Monitor
Shows live CPU execution with debug interface:
```cmd
iverilog -o realtime_sim src\*.v tb\realtime_monitor_tb.v
vvp realtime_sim
gtkwave realtime_cpu.vcd
```
**Features:**
- Live register and memory updates
- Real-time instruction execution display
- Control signal monitoring
- Professional debug interface simulation

### 🧪 Functionality Tests

#### 3. Arithmetic Operations Test
Tests ADD and SUB instructions with various operands:
```cmd
iverilog -o arithmetic_sim src\*.v tb\arithmetic_tb.v
vvp arithmetic_sim
gtkwave arithmetic_test.vcd
```

#### 4. Logical Operations Test  
Tests AND, OR, and XOR instructions with bit patterns:
```cmd
iverilog -o logical_sim src\*.v tb\logical_tb.v
vvp logical_sim
gtkwave logical_test.vcd
```

#### 5. Memory Operations Test
Tests LOAD and STORE instructions for data memory access:
```cmd
iverilog -o memory_sim src\*.v tb\memory_tb.v
vvp memory_sim
gtkwave memory_test.vcd
```

#### 6. Control Flow Test
Tests JMP instruction and program counter behavior:
```cmd
iverilog -o flow_sim src\*.v tb\control_flow_tb.v
vvp flow_sim
gtkwave control_flow_test.vcd
```

#### 7. Comprehensive Test Suite
Complete automated test of all CPU functionality:
```cmd
iverilog -o comprehensive_sim src\*.v tb\comprehensive_tb.v
vvp comprehensive_sim
gtkwave comprehensive_test.vcd
```

#### 8. Basic CPU Test (Original)
Basic testbench with program.mem file:
```cmd
iverilog -o cpu_sim src\*.v tb\cpu_tb.v
vvp cpu_sim
gtkwave cpu.vcd
```

## Run All Tests

To run the complete test suite and verify all CPU functionality:

```cmd
cd "C:\Users\ayush\OneDrive\Desktop\8bitcpu"

echo Running Arithmetic Test...
iverilog -o arithmetic_sim src\*.v tb\arithmetic_tb.v && vvp arithmetic_sim

echo Running Logical Test...  
iverilog -o logical_sim src\*.v tb\logical_tb.v && vvp logical_sim

echo Running Memory Test...
iverilog -o memory_sim src\*.v tb\memory_tb.v && vvp memory_sim

echo Running Control Flow Test...
iverilog -o flow_sim src\*.v tb\control_flow_tb.v && vvp flow_sim

echo Running Comprehensive Test...
iverilog -o comprehensive_sim src\*.v tb\comprehensive_tb.v && vvp comprehensive_sim

echo All tests completed!
```

## Simulation Commands

### Step-by-Step Execontains interactive simulations and functionality tests:

### 🎮 Interactive Simulations
| Testbench | Purpose | User Experience |
|-----------|---------|----------------|
| `interactive_tb.v` | Step-by-step CPU interaction | Simulates debugger/IDE usage |
| `realtime_monitor_tb.v` | Live CPU state monitoring | Real-time execution display |

### 🧪 Functionality Tests  
| Testbench | Purpose | Instructions Tested |
|-----------|---------|-------------------|
| `cpu_tb.v` | Basic test with program.mem | Uses external program file |
| `arithmetic_tb.v` | Arithmetic operations | ADD, SUB, MOV |
| `logical_tb.v` | Logical operations | AND, OR, XOR, MOV |
| `memory_tb.v` | Memory access | LOAD, STORE, MOV |
| `control_flow_tb.v` | Program control | JMP, MOV |
| `comprehensive_tb.v` | Complete test suite | All 9 instructions |

### Key Features:
- **Interactive testbenches** simulate actual user interaction with the CPU
- **Functionality tests** provide automated validation of CPU operations  
- **Real-time monitoring** shows live execution like professional debug tools
- **Step-by-step execution** allows detailed program analysis
- **Comprehensive coverage** tests all instruction types and edge case
   ```
   Executes the testbench and generates `cpu.vcd` waveform file.

4. **View results:**
   ```cmd
   gtkwave cpu.vcd
   ```
   Opens GTKWave to analyze signal waveforms.

### Alternative: PowerShell

For PowerShell users:

```powershell
Set-Location "C:\Users\ayush\OneDrive\Desktop\8bitcpu"
iverilog -o cpu_sim src\*.v tb\cpu_tb.v
vvp cpu_sim
gtkwave cpu.vcd
```

## Testbench Files

The `tb/` directory now contains multiple specialized testbenches:

| Testbench | Purpose | Instructions Tested |
|-----------|---------|-------------------|
| `cpu_tb.v` | Basic test with program.mem | Uses external program file |
| `arithmetic_tb.v` | Arithmetic operations | ADD, SUB, MOV |
| `logical_tb.v` | Logical operations | AND, OR, XOR, MOV |
| `memory_tb.v` | Memory access | LOAD, STORE, MOV |
| `control_flow_tb.v` | Program control | JMP, MOV |
| `comprehensive_tb.v` | Complete test suite | All 9 instructions |

Each testbench:
- Loads specific test programs directly into instruction memory
- Monitors CPU execution and verifies results
- Provides pass/fail output for each test case
- Generates separate waveform files for analysis

## Files Structure

### Comprehensive Test Output Example:
```
=== COMPREHENSIVE CPU TESTBENCH ===
Testing all CPU instructions and functionality

--- PHASE 1: MOV Instructions ---
[PASS] MOV R1, 10: R1 = 10
[PASS] MOV R2, 20: R2 = 20  
[PASS] MOV R3, 5: R3 = 5

--- PHASE 2: Arithmetic Operations ---
[PASS] ADD R4, R1, R2 (10+20): R4 = 30
[PASS] SUB R5, R2, R1 (20-10): R5 = 10

--- PHASE 3: Logical Operations ---
[PASS] AND R6, R1, R3 (10&5): R6 = 0
[PASS] OR R7, R1, R3 (10|5): R7 = 15
[PASS] XOR R0, R1, R3 (10^5): R0 = 15

✓ ALL TESTS PASSED - CPU FULLY FUNCTIONAL
```

### Generated Files:
- **Simulation executables**: `*_sim` (cpu_sim, arithmetic_sim, etc.)
- **Waveform files**: `*.vcd` (cpu.vcd, arithmetic_test.vcd, etc.)
- **Console output**: Pass/fail results for each test casx/WSL
├── tb/                # Testbench files
    ├── cpu_tb.v           # Basic CPU testbench
    ├── interactive_tb.v   # 🎮 Interactive user simulation
    ├── realtime_monitor_tb.v # 🎮 Real-time CPU monitor
    ├── arithmetic_tb.v    # 🧪 Arithmetic operations test
    ├── logical_tb.v       # 🧪 Logical operations test
    ├── memory_tb.v        # 🧪 Memory operations test
    ├── control_flow_tb.v  # 🧪 Control flow test
    └── comprehensive_tb.v # 🧪 # Program counter
│   └── register_file.v      # Register file
└── tb/                # Testbench files
    ├── cpu_tb.v           # Basic CPU testbench
    ├── arithmetic_tb.v    # Arithmetic operations test
    ├── logical_tb.v       # Logical operations test
    ├── memory_tb.v        # Memory operations test
    ├── control_flow_tb.v  # Control flow test
    └── comprehensive_tb.v # Complete test suite
```

## Expected Output

### Interactive CPU Simulation Example:
```
=== INTERACTIVE 8-BIT CPU SIMULATOR ===
>>> User Loading Program: Simple Calculator
>>> Loading user program into instruction memory...
    [0] MOV R1, 15    ; Load first operand
    [1] MOV R2, 10    ; Load second operand  
    [2] ADD R3, R1, R2 ; Calculate sum

>>> User Action: Starting CPU (releasing reset)...
>>> User Action: Single-step execution mode enabled

>>> STEP 1: Executed instruction at PC=0
    Instruction 0x020F: MOV R1, 15
    Registers: R0=0 R1=15 R2=0 R3=0 R4=0 R5=0 R6=0 R7=0
    Next PC: 1

✓ Program completed successfully!
```

### Real-Time Monitor Example:
```
║               8-BIT CPU REAL-TIME MONITOR                  ║
🎯 REAL-TIME EXECUTION MONITOR
┌─────┬─────────┬──────────────┬─────────────────────────────┐
│ Cyc │   PC    │ Instruction  │         Operation           │
├─────┼─────────┼──────────────┼─────────────────────────────┤
│   1 │     0   │    0x0205    │ MOV R1,5                   │
│   2 │     1   │    0x0403    │ MOV R2,3                   │
│   3 │     2   │    0x0108    │ ADD R3,R1,R2               │
└─────┴─────────┴──────────────┴─────────────────────────────┘
    💾 Registers: R0=00 R1=05 R2=03 R3=08 R4=00 R5=00 R6=00 R7=00
```

### Generated Files:
- **Interactive simulation**: `interactive_cpu.vcd`
- **Real-time monitor**: `realtime_cpu.vcd`
- **Functionality tests**: `*_test.vcd` files
- **Console output**: Detailed execution traces and state information

## Test Program

The included `program.mem` contains a test program that:
- Loads immediate values into registers
- Performs arithmetic operations (ADD, SUB)
- Tests logical operations (AND, OR, XOR)
- Demonstrates memory operations (STORE/LOAD)
- Creates an infinite loop for continuous testing

## Troubleshooting

**If compilation fails:**
- Ensure Icarus Verilog is installed and in your PATH
- Check that all `.v` files are present in the correct directories  
- For basic test: Verify `program.mem` exists in the project root
- Try compiling individual testbenches to isolate issues

**If simulation doesn't run:**
- Make sure simulation executable was created successfully (e.g., `cpu_sim`, `arithmetic_sim`)
- Check for syntax errors in Verilog files
- Verify testbench file exists in `tb/` directory

**If tests fail:**
- Check console output for specific failed test cases
- Use GTKWave to examine signal waveforms and timing
- Verify instruction encoding in test programs matches CPU design
- Check that all CPU modules are properly instantiated

**If GTKWave doesn't open:**
- Ensure GTKWave is installed and in PATH
- Verify `.vcd` file was generated after simulation  
- Try opening `.vcd` files manually: `gtkwave filename.vcd`

**Common Issues:**
- **No output**: Check that testbench initializes instruction memory correctly
- **Wrong results**: Verify ALU operations and control unit logic  
- **Timing issues**: Ensure adequate clock periods between test phases
- **Memory problems**: Check data memory read/write timing in testbench

## Modifying the Program

To create your own program:
1. Edit `program.mem` with 16-bit hexadecimal instructions
2. Follow the instruction format: `[opcode][rd][rs1][rs2/immediate]`
3. Recompile and run the simulation

## CPU Features

- **5-stage pipeline concept** (simplified to combinational)
- **Complete datapath** with ALU, register file, and memory
- **Control unit** for instruction decoding
- **Harvard architecture** with separate instruction and data memories
- **Jump capability** for control flow operations