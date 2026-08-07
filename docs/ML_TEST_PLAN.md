# ML Test Plan

## 1. Goal

Verify the ML path in stages:

- MAC
- dot product
- vector ops
- matrix ops

## 2. Test layers

### A. Unit tests

Check each numeric primitive alone.

#### MAC tests

- 1 x 1
- signed values
- unsigned values
- overflow behavior
- clear accumulator

#### Dot product tests

- short vectors
- odd lengths
- zero vectors
- negative values
- widened accumulator correctness

#### Vector tests

- lane extraction
- lane addition
- lane multiply
- lane MAC
- horizontal reduction

#### Matrix tests

- 2x2 multiply
- 4x4 multiply
- non-square dimensions
- tile boundary cases

### B. Integration tests

Check that the CPU and accelerator work together.

- MMIO writes reach control registers
- status polling works
- results land in memory or output register
- CPU can continue after accelerator completion

### C. Regression tests

Prevent breakage as features grow.

- scalar CPU still runs existing programs
- ML path does not break branches or memory
- invalid configurations report errors cleanly

## 3. Suggested first test vectors

### MAC

- `3 * 4 + 0 = 12`
- `-3 * 4 + 0 = -12`
- `7 * 0 + 5 = 5`

### Dot product

- `[1, 2, 3] · [4, 5, 6] = 32`
- `[0, 0, 0] · [7, 8, 9] = 0`

### Vector

- int8 packed add
- int16 packed multiply
- reduction sum across lanes

### Matrix

- identity matrix multiply
- small dense GEMM

## 4. Acceptance criteria

The ML path is ready when:

- MAC returns correct accumulator values
- dot product matches reference software
- vector lanes produce correct per-lane results
- matrix tiles match scalar matrix multiply
- existing CPU behavior remains unchanged

## 5. Debug outputs to watch

- control register state
- busy/done flags
- accumulator value
- result register
- memory writes

