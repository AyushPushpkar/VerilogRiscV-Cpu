# ML Docs Index

## Overview

This folder contains the first ML-focused planning set for the current CPU.

## Documents

- `RISCV_COMPLIANCE.md`  
  What is and is not RISC-V compliant, what has been verified against the
  spec, and the path to conformance. Read this before describing the core
  to anyone.

- `ML_ROADMAP.md`  
  Build order and strategy for MAC, dot product, vectorization, and matrix ops.

- `ML_ACCELERATOR_DESIGN.md`  
  Hardware-oriented design for the ML execution blocks.

- `ML_INTERFACE.md`  
  Proposed control/register interface between the CPU and ML hardware.

- `ML_TEST_PLAN.md`  
  Validation plan for primitives, integration, and regressions.

- `ML_POST_ROADMAP.md`  
  Ranked list of ML workloads to target after the core accelerator work.

- `ML_RTL_IMPLEMENTATION_ORDER.md`  
  Concrete RTL build order for implementing ML blocks.

- `ML_BLOCKS_EXPLAINED.md`  
  Ground-up walkthrough of the scalar ML blocks (`mac_unit`, `dot_product`,
  and their testbenches): what each does, how they connect, and how to run
  the tests. Start here if you are new to the code.

- `ML_BLOCKS_EXPLAINED_2.md`  
  Part 2: packed vector lanes (`vec_mac`), the memory-mapped interface
  (`ml_accel`), how the accelerator hooks into the CPU, and the assembly
  program that drives it end to end.

- `ML_BLOCKS_EXPLAINED_3.md`  
  Part 3: the matrix tile controller (`matrix_tile`, GEMM), the operand
  buffer that makes the streaming engines reachable from software, the DMA,
  and the first ML workload (4-feature linear regression).

- `ML_BLOCKS_EXPLAINED_4.md`  
  Part 4: scale. What broke when the model got bigger — the packed lanes were
  unreachable from the dot-product path, and the operand buffer was a hard
  ceiling rather than a tiling granularity. Then climbs the workload ladder:
  784-feature linear regression, logistic regression (integer sigmoid), and a
  2-layer MLP.

- `ML_BLOCKS_EXPLAINED_5.md`  
  Part 5: learning. DMA write-back (the other half of the memory bottleneck),
  and TRAINING by gradient descent — the network discovers its own weights.
  Covers why integer truncation makes learning stall dead, and the fixed-point
  fix.

- `ML_BLOCKS_EXPLAINED_6.md`  
  Part 6: a convolutional neural network (convolution = sliding dot product,
  weight reuse, im2col), and the capstone reflection — every major bug in the
  series was hardware that was correct in isolation but unreachable in practice.
  **Has the current register map.**

- `CNN_DESIGN.md`  
  The CNN design, written and reviewed against the RTL before coding — which
  caught two operand-layout errors before they became bugs.

## Recommended path

`MAC -> dot product -> vector lanes -> matrix tiles`
