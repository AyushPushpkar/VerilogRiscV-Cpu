# ML Roadmap for the Current CPU

## 1. Where the design is today

Current flow:

`PC -> instruction_memory -> decode/control -> register_file -> ALU -> memory/writeback -> PC`

That is a scalar, single-cycle RV64-style CPU with:

- 64-bit registers and ALU
- loads/stores
- branches and jumps
- RV64M multiply/divide support
- MMIO output support

This is enough to run ML-style code in software, but it is not yet efficient for tensor math.

## 2. What ML workloads need

Most ML kernels reduce to:

- dot product
- multiply-accumulate (MAC)
- vector operations
- matrix multiplication / GEMM

The main pressure points are:

- too many scalar instructions per output
- memory bandwidth limits
- lack of fused arithmetic
- no packed low-precision data path

## 3. Recommended build order

### Phase 1: MAC support

Goal:

- compute repeated `acc = acc + a * b`

Why first:

- MAC is the core operation behind dot product and matrix multiply
- it proves multiply-add throughput
- it removes extra register traffic early

Deliverables:

- accumulator register
- clear/accumulate controls
- support for 8-bit and/or 16-bit operands
- saturating or widened accumulator option
- clean software-visible instruction or accelerator register interface

### Phase 2: Dot-product support

Goal:

- compute `sum += a[i] * b[i]`

Why next:

- dot product is the first complete ML kernel built from MAC
- it is the foundation for fully connected layers and convolutions

Deliverables:

- dot-product loop support
- horizontal reduction path
- configurable signed/unsigned mode
- optional rounding/saturation behavior

### Phase 3: Vectorization

Goal:

- process multiple lanes per instruction

Why next:

- ML speedup comes from parallel element-wise multiply and add
- vector ops improve throughput without changing algorithms

Deliverables:

- packed lanes (example: 8x8-bit or 4x16-bit)
- lane-wise add/mul/macc
- horizontal reduction for dot product
- vector load/store support or lane packing from memory

### Phase 4: Matrix ops

Goal:

- accelerate GEMM / matrix-vector multiply

Why last:

- matrix ops are built from dot products and vector lanes
- best added after the lane and accumulator model is stable

Deliverables:

- tile-based matrix engine
- row/column iteration support
- block accumulator(s)
- optional systolic-style datapath later

## 4. Practical roadmap for this CPU

### Short-term

- keep the existing scalar CPU
- add a small ML coprocessor or custom instruction path
- reuse the register file and memory system where possible

### Mid-term

- add packed arithmetic and wider accumulator registers
- add a fast path for dot-product style loops
- add instruction support for vector/matrix control

### Long-term

- move from scalar execution to tiled vector execution
- add optional DMA or burst memory fetches
- consider a matrix engine if workloads demand it

## 5. What to prioritize first

If the goal is ML on this CPU, the order should be:

1. MAC
2. Dot product
3. Packed vector ops
4. Matrix ops

Reason:

- MAC powers dot product directly
- dot product powers most small ML kernels
- vector ops unlock practical speedups
- matrix ops are the final layer for larger models

## 6. Success criteria

You are ready for ML-friendly work when you can:

- multiply and accumulate low-precision values efficiently
- run a dot product with far fewer instructions than today
- keep the accumulator wider than the input data type
- process more than one element per cycle or per instruction
