# ML Accelerator Design

## 1. Design goal

Add ML-focused hardware around the current RV64-style CPU so the system can efficiently execute:

- dot product
- multiply-accumulate (MAC)
- vector operations
- matrix operations

The current CPU remains the control core. The accelerator handles dense numeric work.

## 2. Current baseline

Today the CPU already has:

- instruction fetch/decode
- register file
- ALU with multiply/divide
- memory access
- branch/jump control

What it does not have:

- packed low-precision lanes
- a fused accumulator path
- horizontal reductions
- matrix tiling support
- bandwidth-aware bulk data movement

## 3. Datapath strategy

Use a layered design:

1. scalar control CPU
2. MAC / dot-product execution block
3. vector lane block
4. matrix tile block

This keeps the system simple and allows incremental growth.

## 4. Dot product unit

### Function

Compute:

`y = sum(a[i] * b[i])`

### Core blocks

- operand unpacker
- multiplier array or time-multiplexed multiplier
- accumulator register
- optional widening/saturation logic

### Suggested interfaces

- `start`
- `clear_acc`
- `vector_len`
- `mode` (signed / unsigned / mixed)
- `lane_width`
- `done`
- `result`

### Behavior

- load two vectors
- multiply lane pairs
- add partial products into accumulator
- expose final sum to CPU register file or memory

## 5. MAC unit

### Function

Compute:

`acc = acc + a * b`

### Why separate from dot product

Dot product is a loop over MACs. A dedicated MAC unit is the most reusable primitive.

### Recommended features

- accumulator register with wider precision than inputs
- signed/unsigned selection
- optional rounding
- optional saturation
- reset/clear path

### Good ML widths

- inputs: 8-bit or 16-bit
- accumulator: 32-bit or 64-bit

## 6. Vectorization design

### Goal

Process several values per operation.

### Example lane options

- 8 x int8
- 4 x int16
- 2 x int32

### Supported operations

- lane add/sub
- lane multiply
- lane MAC
- lane compare
- lane min/max
- horizontal add/reduction

### Required hardware

- packed register view
- lane shifters / extractors
- lane-wise control decode
- reduction tree for dot product

### CPU integration

Options:

- custom vector opcodes
- coprocessor register interface
- memory-mapped accelerator registers

For this project, a coprocessor interface is the cleanest first step.

## 7. Matrix ops design

### Goal

Accelerate matrix-vector and matrix-matrix multiplication.

### Core idea

Break matrices into tiles and reuse dot-product blocks on each tile.

### Hardware elements

- tile controller
- row/column iterators
- local accumulator bank
- bulk load/store path
- optional scratchpad memory

### Work pattern

- load a tile of A
- load a tile of B
- accumulate partial sums
- write back C

### Why this comes after vectorization

Matrix ops are mostly orchestration around vector MACs and dot products.

## 8. Memory and bandwidth

ML speed is often limited by memory, not arithmetic.

Recommended additions:

- burst reads for vector blocks
- aligned packed loads/stores
- scratchpad/local buffer
- optional DMA later

Without this, the accelerator will stall waiting on scalar memory traffic.

## 9. Control and ISA options

Possible integration styles:

1. custom instructions
2. memory-mapped control registers
3. separate accelerator command queue

Recommended sequence:

- start with memory-mapped control registers
- move to custom instructions later if tighter coupling is needed

## 10. Precision roadmap

Suggested numeric order:

1. int32 baseline
2. int16 packed lanes
3. int8 packed lanes
4. optional fixed-point support

Reason:

- easier bring-up at higher precision
- then optimize for ML throughput

## 11. Implementation roadmap

### Stage A

- add MAC engine
- expose accumulator
- verify with scalar tests

### Stage B

- add dot-product loop support
- add packed int16 or int8 lanes
- validate lane reduction

### Stage C

- add vector register packing
- add vector load/store helpers
- benchmark against scalar CPU

### Stage D

- add tiled matrix execution
- add scratchpad / burst transfer support
- tune for GEMM-style workloads

## 12. Final recommendation

Do not jump directly to a full matrix engine.

Best path:

`MAC -> dot product -> vector lanes -> matrix tiles`

That sequence matches both hardware reuse and ML workload needs.

