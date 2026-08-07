# ML Interface Design

## 1. Purpose

Define how the current CPU should talk to future ML hardware for:

- dot product
- MAC
- vector operations
- matrix operations

## 2. Integration choice

Best first step: **memory-mapped accelerator control**.

Why:

- easy to hook into the existing CPU
- does not require immediate ISA changes
- works well for bring-up and testing

## 3. Proposed accelerator registers

### Control block

- `ML_CTRL`
  - start
  - clear accumulator
  - operation select
  - signed/unsigned mode
  - lane width select

- `ML_STATUS`
  - busy
  - done
  - error

### Data block

- `ML_A`
  - operand buffer A pointer or packed input

- `ML_B`
  - operand buffer B pointer or packed input

- `ML_ACC`
  - accumulator value

- `ML_LEN`
  - element count / vector length

- `ML_OUT`
  - final result

## 4. Operation model

### MAC

Write operands and start:

`acc = acc + a * b`

### Dot product

Set length and run repeated MACs:

`sum = Σ(a[i] * b[i])`

### Vector ops

Use packed lanes:

- int8 lanes
- int16 lanes
- int32 lanes

### Matrix ops

Program tile sizes and run repeated vector/dot-product blocks.

## 5. Software control flow

Typical sequence:

1. load operands into memory or accelerator-visible buffers
2. configure control register
3. write length and mode
4. assert start
5. poll done
6. read result

## 6. Design rules

- keep accumulator wider than inputs
- separate start and clear signals
- keep MMIO registers aligned and simple
- avoid overloading the scalar CPU datapath

## 7. Future ISA option

If software overhead becomes a problem later, the same interface can be mirrored with custom instructions.

