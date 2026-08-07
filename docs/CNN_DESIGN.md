# Small CNN — Design

Rung 6 of [ML_POST_ROADMAP.md](ML_POST_ROADMAP.md), and the reason to skip rungs
4 and 5: the roadmap itself says *"CNNs are a better hardware fit than KNN,"* and
it is right. A convolution **is** a sliding dot product — precisely the operation
this accelerator was built around.

This document is the plan. No code yet.

---

## 1. What a convolution actually is

A convolutional layer slides a small **filter** (a grid of weights) across an
**image**, and at each position computes one number: the dot product of the
filter with the image patch underneath it.

```
   image (4×4)              filter (3×3)          output (2×2)
   ┌─────────────┐          ┌─────────┐           ┌───────┐
   │ 1  2  0  1  │          │ 1  0  1 │           │ .  .  │
   │ 0  3  1  2  │    ⊛     │ 0  2  0 │     =     │ .  .  │
   │ 2  1  4  1  │          │-3  0 -3 │           └───────┘
   │ 1  0  2  3  │          └─────────┘
   └─────────────┘
```

Slide the 3×3 filter over the 4×4 image and it fits in **4 positions** (2 across,
2 down — "valid" convolution, no padding). Each position produces one output, so
the result is a **2×2 feature map**.

### The one insight that makes it hardware-friendly

**Each output is a dot product.** Flatten the 3×3 filter into a 9-element vector,
flatten the 3×3 image patch under it into another 9-element vector, and the
convolution output at that position is:

```
out[i][j] = filter · patch[i][j]
```

That is exactly `OP_DOT`. Nothing new is needed — the accelerator already does
this, and at `LANE_8` it does 8 of the 9 multiply-accumulates in a single cycle.

---

## 2. The genuinely new idea: weight reuse

Everything before this loaded operands, used them once, and moved on. A
convolution is different, and it is *the* defining property of a CNN:

> **The same filter weights are used at every output position.**

The 9 filter values are loaded **once** and reused across all 4 windows. In a
real CNN — a 3×3 filter over a 224×224 image — those same 9 weights are reused
**~50,000 times.** This is why CNNs are such a good accelerator fit: the
expensive thing (the weights) stays put, and only the cheap thing (the image
window) moves.

Concretely, on this accelerator. **The operand roles are dictated by how
`matrix_tile` indexes its buffers**, verified against the RTL:

```
mat_a_idx = row * k_chunks + k_chunk    A is indexed by ROW  (the M dimension)
mat_b_idx = col * k_chunks + k_chunk    B is indexed by COL  (the N dimension)
```

With **M = 4, N = 1**, `mat_b_idx` only ever sees `col = 0` — so **operand B is
read once per output and reused across all four rows.** That makes the mapping:

- The **4 windows** are operand **A** — the "matrix," one row per output position.
- The **filter** is operand **B** — the single column, **reused** across all four
  rows. This is the weight reuse, and it falls directly out of `N = 1`.
- `OP_MAT` with **M = 4, N = 1, K = 9** computes all four dot products in one run.

This is the same operand assignment the working MLP-matrix program uses
([program_mlp_mat.asm](../program_mlp_mat.asm)): the weight *matrix* is A, the
reused *vector* is B. A CNN filter is that reused vector.

### K = 9 spans two chunks

At `LANE_8` a chunk holds 8 int8 values, so K = 9 needs `ceil(9/8) = 2` chunks per
row — 16 slots, of which **7 are padding.** The padding lanes must be **zero**, so
they contribute `0 × 0 = 0` and are invisible to the dot product. This is not a
special case: `matrix_tile` already handles a K that is not a multiple of the lane
count, and `tb_matrix_tile.v` tests exactly K = 9 (`"K=9 (spans 2 chunks)"`).

Consequences for the layout:

- Operand A (the windows) is a **4 × 2-chunk** block = 8 doublewords, not 4.
- `ML_CNT` for A must be `M × k_chunks = 4 × 2 = 8`.
- Operand B (the filter) is `1 × 2 = 2` chunks.

---

## 3. The concrete example

Small enough to verify by hand, real enough to be a convolution.

**Image (4×4, int8):**
```
1  2  0  1
0  3  1  2
2  1  4  1
1  0  2  3
```

**Filter (3×3):**
```
 1   0   1
 0   2   0
-3   0  -3
```

The negative bottom row is deliberate — it makes most windows go negative, so
**ReLU actually fires.** A CNN whose activation never triggers proves nothing (a
lesson from the MLP, where the first weights left ReLU dormant).

**The 4 windows, flattened to 9-vectors:**

| Position | Flattened window |
|---|---|
| (0,0) | `[1,2,0, 0,3,1, 2,1,4]` |
| (0,1) | `[2,0,1, 3,1,2, 1,4,1]` |
| (1,0) | `[0,3,1, 2,1,4, 1,0,2]` |
| (1,1) | `[3,1,2, 1,4,1, 0,2,3]` |

**Filter flattened:** `[1,0,1, 0,2,0, -3,0,-3]`

**Convolution → ReLU:**

```
out[0][0] = -11  →  ReLU →  0     clamped
out[0][1] =  -1  →  ReLU →  0     clamped
out[1][0] =  -6  →  ReLU →  0     clamped
out[1][1] =   4  →  ReLU →  4
                              ---
              feature map sum =  4     ← published
```

Without ReLU the sum would be **-14**, so the activation is load-bearing — the
test can tell "ReLU works" from "ReLU skipped."

---

## 4. How it runs on the accelerator

```
1. im2col      software flattens each 3×3 window into a 9-value row, ZERO-PADDED
               to 16 (two int8 chunks). The 4 windows become a 4×16 block in RAM
               = operand A, 8 doublewords.

2. filter      the 9 filter weights, likewise zero-padded to 16 = operand B,
               2 doublewords. This is the reused operand (N=1).

3. OP_MAT      M=4, N=1, K=9.  ML_CNT: A=8 chunks, B=2 chunks.
               4 dot products, one per window; the filter (B) reused across all.

4. ReLU        max(0, x) per output — one branch each, as in the MLP.

5. sum + publish
```

### im2col — the one piece of real new software

"im2col" (image-to-column) is the standard way every ML framework turns a
convolution into a matrix multiply. It is exactly what step 1 does: unroll each
overlapping window into a contiguous row so the matrix engine can consume it.

It is **pure software** — address arithmetic to gather the 9 pixels of each
window. No new hardware. It is also the honest cost of this approach: the windows
overlap, so im2col duplicates pixels (the 4 windows here hold 36 values built
from 16 pixels). Real accelerators sometimes avoid this with dedicated
sliding-window hardware, but im2col is the simple, standard, correct choice and
it reuses `OP_MAT` unchanged.

---

## 5. What this does and does not need

**Needs no new RTL.** Convolution = dot product = `OP_MAT`. ReLU = a branch. The
accelerator, the DMA, the tiling, the CPU — all frozen. This is the whole reason
the CNN is the right next step: maximum reuse, zero blast radius on a base that
has 23 passing testbenches.

**New software only:**
- `im2col` window gathering (address arithmetic)
- driving `OP_MAT` with conv dimensions
- per-output ReLU and the final reduction

---

## 6. Test plan

`program_cnn.asm` + `tb/tb_cpu_cnn.v`:

- The testbench builds the image and filter, computes the reference convolution
  **and** the reference ReLU output in software, and writes the image + filter
  into RAM.
- The hardware runs im2col → `OP_MAT` → ReLU → sum.
- Checks:
  - each of the 4 raw convolution outputs against the software reference
  - the ReLU output (3 of 4 clamped to 0)
  - the published sum == 4
  - **not** the no-ReLU sum (-14) — reported by name as "activation skipped" if
    it appears, so a dormant ReLU cannot pass
- Watches `mat_c_valid` to confirm all 4 outputs come from **one** `OP_MAT` run —
  proving the filter was reused, not reloaded per window.

**Expected:** 4 convolution outputs correct, 3 ReLU clamps, sum = 4, one OP_MAT
run, zero faults.

---

## 7. Where it sits

| Rung | Workload | Status |
|---|---|---|
| 1 | Linear regression | done |
| 2 | Logistic regression | done |
| 3 | MLP | done |
| — | Training | done |
| 6 | **Small CNN** | **done — `program_cnn.asm`, `tb_cpu_cnn.v`** |
| 4, 5 | KNN, K-means | skipped (CNN is the better fit) |
| 7, 8 | RNN, Transformer | later |

After this, the distance-kernel workloads (KNN, K-means) become the natural
follow-ups, and only the Transformer's softmax threatens to need new hardware.
