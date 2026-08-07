# RV64 CPU with ML Accelerator

A Verilog implementation of a single-cycle RV64 RISC-V CPU, with a memory-mapped
machine-learning accelerator for packed integer dot products, matrix multiply,
and bidirectional DMA. Runs real ML workloads end to end: MNIST-scale
(784-feature) linear regression, logistic regression with an integer sigmoid, a
2-layer neural network, **gradient-descent training**, and a **convolutional
neural network** — all in integer arithmetic.

> **Compliance:** an RV64IM core with a partial Zbb subset, verified against the
> spec for instruction semantics. **Not privileged-spec conformant** — no CSRs,
> no traps, no `ECALL`. See [docs/RISCV_COMPLIANCE.md](docs/RISCV_COMPLIANCE.md)
> for the full accounting.

## Specifications

| Feature | Value |
|---------|-------|
| Architecture | RV64I + RV64M + selected Zbb |
| Data Width | 64 bits (XLEN = 64) |
| Instruction Width | 32 bits |
| Registers | 32 general-purpose (x0–x31), `x0` hardwired to zero |
| Instruction Memory | 1024 × 32-bit ROM, loaded from `program.mem` |
| Data Memory | 2 KB RAM (1920 usable; top 128 bytes are MMIO) |
| Memory Model | Harvard (separate I/D memory) |
| Execution Model | Single-cycle |

## Memory map

| Address | Purpose |
|---|---|
| `0x000`–`0x77F` | Data RAM (1920 bytes) |
| `0x780`–`0x7D0` | ML accelerator registers (16 slots, 8-byte spaced) |
| `0x7F8` | MMIO output port (`out_port`) |

All MMIO registers are doubleword-aligned because RISC-V permits `SD`/`LD` only
at 8-byte-aligned addresses.

## Core modules

| Module | Function |
|--------|----------|
| `cpu_top.v` | Top-level integration & datapath |
| `control_unit.v` | Instruction decode & control signals |
| `pre_decoder.v` | Instruction field extraction |
| `alu.v` | RV64I + RV64M + Zbb subset ALU |
| `imm_gen.v` | Immediate generation (I/S/B/U/J formats) |
| `register_file.v` | Dual-read, single-write, `x0` = 0 |
| `program_counter.v` | 64-bit PC |
| `instruction_memory.v` | Instruction ROM |
| `data_memory.v` | Byte-addressed RAM with load/store widths |
| `mux2x1.v` | Generic 2-to-1 multiplexer |
| `defines.v` | Opcode / funct3 / funct7 constants |

## ML accelerator

| Module | Function |
|--------|----------|
| `mac_unit.v` | Multiply-accumulate primitive, widened accumulator |
| `vec_mac.v` | Packed lanes: 8× int8, 4× int16, 2× int32, 1× int64 per cycle |
| `dot_product.v` | FSM streaming MACs over a whole vector |
| `matrix_tile.v` | GEMM — a dot product per output element, reusing `vec_mac` |
| `ml_accel.v` | Memory-mapped front end; operand buffer, bidirectional DMA, engine select |

**Scale.** At `LANE_8` the accelerator processes 8 int8 features per cycle. Vectors
larger than the 64-chunk operand buffer are **tiled**: run each tile with
`ML_CTRL[8]` (accumulate) set, and partial sums add up inside the 128-bit
accumulator without ever being rounded. A 784-feature MNIST-scale dot product runs
in 98 MAC cycles and 48 instructions — the scalar equivalent needs ~3,136.

At `LANE_8`, eight int8 multiply-accumulates run per cycle from the same 64-bit
operand wires — an 8× throughput gain over scalar. Driven entirely by standard
`SD`/`LD` instructions; **no custom opcodes, no ISA changes**.

Three operating modes, selected by `ML_CTRL[6:5]`:

| `op` | Mode | One `start` does |
|---|---|---|
| 0 | `OP_MAC` | one packed multiply-accumulate |
| 1 | `OP_DOT` | an entire vector dot product |
| 2 | `OP_MAT` | an entire matrix multiply |

Software fills the operand buffer (`ML_A`/`ML_B` auto-increment), sets
dimensions in `ML_LEN`, writes `start`, polls `ML_STATUS`, and reads the result.

**Or it doesn't fill anything at all.** The accelerator has a **DMA** engine: point
`ML_SRC_A`/`ML_SRC_B` at operands already in RAM, set `ML_CNT`, and pulse
`ML_CTRL[7]` — the accelerator fetches them itself at one doubleword per cycle.
Filling a 64-entry buffer costs 4 instructions instead of 64, and that cost is
constant rather than proportional to the vector length.

## ML workloads

Real models, running on the hardware — all integer, no floating point:

| Workload | What it demonstrates |
|---|---|
| **Linear regression** | 784 features (MNIST-scale) in 98 MAC cycles — **65×** fewer instructions than scalar |
| **Logistic regression** | Binary classification. The class is a **sign test** (`sigmoid(z)>0.5 ⟺ z>0`); the probability comes from an integer **Q8 lookup table** — what production quantized ML actually does |
| **2-layer MLP** | A neural network. **ReLU** is one branch, and the hidden layer's output feeds back in as the next layer's input. A whole layer runs in **one** `OP_MAT` — 13× fewer instructions than one dot product per neuron at 128 neurons |
| **Training** | Gradient descent. The network **learns** `w = [3,-2,1,4]` from data it has never been told. No division — the learning rate is a **right shift**. Weights and error are held in **Q8 fixed point**, because truncating to integers makes learning stall dead |
| **CNN** | A convolution is a **sliding dot product**. All 4 outputs come from **one** `OP_MAT` run with the filter reused across windows — the weight reuse that defines a CNN |

Start with [docs/ML_BLOCKS_EXPLAINED.md](docs/ML_BLOCKS_EXPLAINED.md) if you are
new to the code; [part 6](docs/ML_BLOCKS_EXPLAINED_6.md) has the current register
map.

## Building and running

### Everything
```sh
run.bat                    # base CPU + GTKWave
```

### Individual testbenches
```sh
# Base CPU
iverilog -I src -o cpu.vvp src/*.v tb/tb_cpu.v && vvp cpu.vvp

# ISA compliance program (runs on the real CPU)
python tools/assembler.py program_isa.asm program_isa.mem
iverilog -I src -o isa.vvp src/*.v tb/tb_cpu_isa.v && vvp isa.vvp

# ML accelerator, end to end
python tools/assembler.py program_ml.asm program_ml.mem
iverilog -I src -o ml.vvp src/*.v tb/tb_cpu_ml.v && vvp ml.vvp

# Matrix multiply (GEMM) on the accelerator
python tools/assembler.py program_mat.asm program_mat.mem
iverilog -I src -o mat.vvp src/*.v tb/tb_cpu_mat.v && vvp mat.vvp

# DMA: the accelerator fetches its own operands from RAM
python tools/assembler.py program_dma.asm program_dma.mem
iverilog -I src -o dma.vvp src/*.v tb/tb_cpu_dma.v && vvp dma.vvp

# Linear regression inference - a real ML workload
python tools/assembler.py program_linreg.asm program_linreg.mem
iverilog -I src -o lr.vvp src/*.v tb/tb_cpu_linreg.v && vvp lr.vvp

# 64 features, packed int8 lanes
python tools/assembler.py program_linreg8.asm program_linreg8.mem
iverilog -I src -o lr8.vvp src/*.v tb/tb_cpu_linreg8.v && vvp lr8.vvp

# 784 features (MNIST scale), software-tiled
python tools/assembler.py program_mnist.asm program_mnist.mem
iverilog -I src -o mn.vvp src/*.v tb/tb_cpu_mnist.v && vvp mn.vvp

# Logistic regression - binary classification, integer sigmoid LUT
python tools/assembler.py program_logreg.asm program_logreg.mem
iverilog -I src -o lg.vvp src/*.v tb/tb_cpu_logreg.v && vvp lg.vvp

# 2-layer MLP - a neural network (ReLU, layer chaining)
python tools/assembler.py program_mlp.asm program_mlp.mem
iverilog -I src -o mlp.vvp src/*.v tb/tb_cpu_mlp.v && vvp mlp.vvp

# MLP with a whole layer in ONE OP_MAT run
python tools/assembler.py program_mlp_mat.asm program_mlp_mat.mem
iverilog -I src -o mm.vvp src/*.v tb/tb_cpu_mlp_mat.v && vvp mm.vvp

# TRAINING - the network learns its own weights
python tools/assembler.py program_train.asm program_train.mem
iverilog -I src -o tr.vvp src/*.v tb/tb_cpu_train.v && vvp tr.vvp

# CNN - convolution as a sliding dot product
python tools/assembler.py program_cnn.asm program_cnn.mem
iverilog -I src -o cnn.vvp src/*.v tb/tb_cpu_cnn.v && vvp cnn.vvp
```

### Compliance suite

Vectors are generated from the spec, not from the RTL. Regenerate them first:

```sh
python tools/gen_imm_vectors.py    imm_vec.txt     400
python tools/gen_alu_vectors.py    alu_vec.txt    3000
python tools/gen_branch_vectors.py branch_vec.txt 1200

iverilog -I src -o alu.vvp src/alu.v tb/tb_alu_compliance.v && vvp alu.vvp
iverilog -I src -o imm.vvp src/imm_gen.v tb/tb_imm_compliance.v && vvp imm.vvp
iverilog -I src -o br.vvp  src/alu.v tb/tb_branch_compliance.v && vvp br.vvp
iverilog -I src -o ld.vvp  src/data_memory.v tb/tb_ldst_compliance.v && vvp ld.vvp
```

**Current status: 9,901 checks across 24 testbenches, 0 errors.**

## Assembler

```sh
python tools/assembler.py program.asm program.mem
```

Supports RV64I/RV64M mnemonics and labels. Note that programs must **halt
explicitly** (`JAL x0, self`) — without it the PC runs into zeroed ROM, which
decodes as an illegal instruction.

## Documentation

| Doc | Contents |
|---|---|
| [RISCV_COMPLIANCE.md](docs/RISCV_COMPLIANCE.md) | What is and is not spec-compliant, and why |
| [ML_BLOCKS_EXPLAINED.md](docs/ML_BLOCKS_EXPLAINED.md) | MAC and dot product, from scratch |
| [ML_BLOCKS_EXPLAINED_2.md](docs/ML_BLOCKS_EXPLAINED_2.md) | Packed lanes, MMIO, CPU integration |
| [ML_BLOCKS_EXPLAINED_3.md](docs/ML_BLOCKS_EXPLAINED_3.md) | GEMM, operand buffer, DMA |
| [ML_BLOCKS_EXPLAINED_4.md](docs/ML_BLOCKS_EXPLAINED_4.md) | Scale: packed lanes, tiling, MNIST, the workload ladder |
| [ML_BLOCKS_EXPLAINED_5.md](docs/ML_BLOCKS_EXPLAINED_5.md) | Learning: DMA write-back, gradient-descent training |
| [ML_BLOCKS_EXPLAINED_6.md](docs/ML_BLOCKS_EXPLAINED_6.md) | CNN, and the series' recurring lesson — current register map |
| [ML_INDEX.md](docs/ML_INDEX.md) | Index of the ML planning docs |
