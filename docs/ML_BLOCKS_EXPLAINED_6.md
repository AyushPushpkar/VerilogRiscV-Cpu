# ML Blocks Explained, Part 6 — Convolution, and What the Whole Thing Taught

Continues [ML_BLOCKS_EXPLAINED_5.md](ML_BLOCKS_EXPLAINED_5.md). Same assumption:
no prior familiarity with the code.

Part 5 closed the training loop — the network could learn its own weights. This
part runs a **convolutional neural network**, the workload most people picture
when they hear "deep learning." And because it is the last workload in this
series, it is also where the recurring lesson finally gets named.

There is a companion design document, [CNN_DESIGN.md](CNN_DESIGN.md), written and
reviewed against the RTL *before* any code. That review is part of the story.

---

## 1. A convolution is a dot product wearing a costume

A convolutional layer sounds exotic. It is not. It slides a small grid of weights
— the **filter** — across an image, and at each position computes the dot product
of the filter with the patch underneath it.

```
   image (4×4)          filter (3×3)        output (2×2)
   1  2  0  1                                ┌───────┐
   0  3  1  2      ⊛     1  0  1      =      │ .   . │
   2  1  4  1            0  2  0             │ .   . │
   1  0  2  3           -3  0 -3             └───────┘
```

A 3×3 filter fits in a 4×4 image at **4 positions** (valid convolution). Flatten
the filter into a 9-element vector, flatten each 3×3 patch into a 9-element
vector, and:

```
output[position] = filter · patch[position]
```

That is `OP_DOT`. The accelerator built across parts 1–5 does convolution with
**no new hardware at all** — which is exactly why the roadmap ranks a CNN above
KNN, and why parts 4 and 5 of the roadmap (KNN, K-means) were skipped to get here.

---

## 2. The one new idea: weight reuse

Every workload before this loaded its operands, used them once, and discarded
them. A CNN is the first that does not, and this is *the* property that defines
it:

> **The same filter weights are used at every output position.**

Load the 9 filter weights **once**, and reuse them across all 4 windows. In a real
CNN — a 3×3 filter over a 224×224 image — those same 9 weights are reused
**~50,000 times.** The expensive thing (the weights) stays put; only the cheap
thing (the image window) moves. That asymmetry is *why* CNNs are such a good
accelerator target.

On this hardware it falls out of `OP_MAT` with **N = 1**:

- The **4 windows** are operand **A** — the "matrix," one row per output.
- The **filter** is operand **B** — and because `matrix_tile` reads B by *column*
  index, with N = 1 it reads B **once and reuses it for every row.**
- One `OP_MAT` run, `M = 4, N = 1, K = 9`, produces all four outputs with the
  filter fetched a single time.

You can watch the reuse happen. The testbench confirms all four convolution
outputs come from **one** `OP_MAT` run — not four separate dot products.

---

## 3. im2col — the standard trick, and its honest cost

The windows overlap. To hand them to the matrix engine, software **flattens each
3×3 window into a contiguous row** — the operation every ML framework calls
**im2col** (image-to-column).

It is pure software: address arithmetic to gather 9 pixels per window. No hardware.

Its honest cost is **duplication**: because the windows overlap, im2col copies
pixels. The four windows here hold 36 values built from just 16 image pixels.
Real accelerators sometimes avoid this with dedicated sliding-window hardware, but
im2col is the simple, standard, correct choice — and it reuses `OP_MAT`
completely unchanged.

---

## 4. It runs

[program_cnn.asm](../program_cnn.asm), with the filter's negative bottom row
chosen so **ReLU actually fires**:

```
OP_MAT: all 4 conv outputs, ONE run     ← filter fetched once, reused
  conv 0 = -11  →  ReLU →  0     clamped
  conv 1 =  -1  →  ReLU →  0     clamped
  conv 2 =  -6  →  ReLU →  0     clamped
  conv 3 =  +4  →  ReLU →  4

feature-map sum = 4      (without ReLU it would be -14)
```

Three of four outputs clamp, so the activation is load-bearing. The testbench
checks the four raw convolution values against a software reference, confirms the
single `OP_MAT` run, and reports "activation skipped" by name if it ever sees the
no-ReLU sum of −14. Zero faults.

---

## 5. K = 9 and the padding lanes

A detail worth calling out, because it is where a naive attempt would break.

`K = 9`, but `LANE_8` packs 8 int8 values per chunk. So each window needs
`ceil(9/8) = 2` chunks — **16 slots for 9 values, 7 of them padding.**

The padding lanes must be **zero**, so they contribute `0 × 0 = 0` and are
invisible to the dot product. This is not a special case bolted on for the CNN:
`matrix_tile` already handles a `K` that is not a multiple of the lane count, and
`tb_matrix_tile.v` tests **exactly** `K = 9`. The convolution rides on hardware
that was already proven for this shape.

---

## 6. The thing this whole series was really about

Six parts, one recurring bug. It is worth stating plainly, because it is the most
transferable lesson here.

**Every major bug in this accelerator was hardware that was correct in isolation
but unreachable in practice.**

| Where | Correct in isolation | But unreachable because… | Found by |
|---|---|---|---|
| Packed lanes | `tb_vec_mac` passed | `dot_product` wrapped the *scalar* MAC | scaling to 64 features |
| Tiling | accumulator was 128-bit | `dot_product` always *cleared* it | scaling to 784 features |
| `matrix_tile` | 84 checks passed | the DMA had one shared operand count | driving a real GEMM |

Each block passed its own unit tests. Each was **wrong only in combination**, and
each was exposed **only by a workload big enough or real enough to reach it.**
`vec_mac` was flawless — and did nothing, because nothing drove it correctly.

There is a second, related bug that appeared **four times**: a *registered* signal
gating *combinational* data that changed in the same cycle (`mac_en`, `c_valid`,
`op_reg`, `dma_wr_en`). The rule, earned the hard way:

> **A qualifier and the data it qualifies must be asserted in the same cycle.**

### The CNN is the first workload built the right way

Every earlier workload found its bug *during* implementation — the bug and the
program arrived together. The CNN did not, and the difference is deliberate:

**[CNN_DESIGN.md](CNN_DESIGN.md) was written and reviewed against the RTL before a
single line of assembly.** That review caught two errors in the plan:

1. The operand roles were backwards. The first draft had the filter as operand A;
   the code reads B as the reused operand at N = 1, so the filter had to be B.
2. The K = 9 layout ignored the two-chunk padding.

Both were fixed **in the document**, against the code, before they could become
bugs in the program. The result: the CNN ran correctly on the first attempt.

That is the lesson the earlier parts taught, applied: **unit tests prove a block
is correct; only a real workload proves it is reachable — so ground the plan
against the actual RTL before you write the workload.**

---

## 7. The ladder, and what remains

| Rung | Workload | Status |
|---|---|---|
| 1 | Linear regression | done — 784 features, tiled |
| 2 | Logistic regression | done — integer sigmoid LUT |
| 3 | MLP | done — ReLU, `OP_MAT` per layer |
| — | Training | done — gradient descent |
| 6 | **Small CNN** | **done — this part** |
| 4, 5 | KNN, K-means | skipped (CNN is the better fit) |
| 7, 8 | RNN, Transformer | remain |

**Everything through here needed no new RTL beyond part 5.** The accelerator has
been feature-frozen since the DMA write-back path, and five workloads plus
training have run on it unchanged.

What remains:

- **RNN/GRU** — matrix-vector multiplies (have them) plus sequential state (the
  MLP's layer-chaining, extended over time). Still pure software.
- **Transformer** — attention is matmuls, but **softmax needs `exp()`**, whose
  dynamic range a single LUT does not cover cleanly. This is the first workload
  that might justify new hardware.
- **The CPU still cannot trap** — no CSRs, no `ECALL`. Unrelated to the
  accelerator, but the largest gap between "correct semantics" and "a CPU that
  could boot something." See [RISCV_COMPLIANCE.md](RISCV_COMPLIANCE.md).

The accelerator's job is essentially done. It computes dot products and matrix
multiplies over packed integers, fetches and writes its own memory, tiles beyond
its buffer, accumulates across runs, and has carried linear and logistic
regression, an MLP, gradient-descent training, and a convolutional network —
every one of them in pure integer arithmetic, driven entirely by `SD`/`LD`, with
**not one change to the RISC-V instruction set.**
