# ML Blocks Explained, Part 5 — Learning

Continues [ML_BLOCKS_EXPLAINED_4.md](ML_BLOCKS_EXPLAINED_4.md). Same assumption:
no prior familiarity with the code.

Parts 1–4 built an accelerator and ran **inference** on it — executing models
that someone else had already trained. This part covers the two things that
close that loop:

- **DMA write-back** — results go straight to RAM instead of being read out one
  load at a time
- **Training** — the network *learns* its own weights from data

Those two are related, and not by accident: **training's entire job is writing
updated weights back.** You cannot have one without the other.

---

## 1. The other half of the bottleneck

Part 3 added a DMA so the accelerator could **read** its operands from memory
itself, instead of software pushing them in one `SD` at a time. That fixed the
input side.

But the **output side was still one-at-a-time.** Results came back through
`ML_ACC_LO`, one `LD` per element:

```
OP_MAT output of M × N elements   →   M × N software loads
```

For an 8×8 GEMM that is 64 loads. Once the DMA had removed the input bottleneck,
**this became the new one** — the classic outcome of fixing only one side of a
pipe.

### The fix: a write port

`data_memory` gains a **third port** — a doubleword write, for the accelerator.

The safety argument is the same as for the read port, and worth repeating because
it is what makes this cheap: **the accelerator only writes while it is busy, and
the CPU is stalled polling `ML_STATUS` during that entire window.** They never
contend, so no arbitration logic is needed.

Inside `ml_accel`, a new **`D_OUT`** state walks the result buffer (`c_buf`) and
writes each entry to RAM, one doubleword per cycle:

| New | What it does |
|---|---|
| `ML_DST` (idx 10) | Destination address in RAM |
| `ML_CTRL[9]` | Pulse: write the results back |

**M × N loads become one control write.** The cost is now flat in the output
size, exactly as the input-side DMA made it flat in the operand size.

### The bug I did not make this time

The write port is driven **combinationally** from the state:

```verilog
assign dma_we    = (dma_state == D_OUT);
assign dma_waddr = dst_reg + {dma_i[BUF_AW-1:0], 3'b000};
assign dma_wdata = c_buf[dma_i[BUF_AW-1:0]][XLEN-1:0];
```

`dma_i` indexes `c_buf`, and the value must be on the bus **during the same
cycle** `dma_we` is high. Registering the enable would fire it one cycle *after*
the index advanced — writing the wrong element to every address.

That is the **phase-alignment bug this codebase has now made four times**
(`dot_product`'s `mac_en`, `matrix_tile`'s `c_valid`, `ml_accel`'s `op_reg`, the
DMA's `dma_wr_en`). It did not become a fifth. The rule, once more:

> **A qualifier and the data it qualifies must be asserted in the same cycle.**

---

## 2. Training — the network learns

Everything before this ran a model. **This one discovers one.**

### What gradient descent actually is

You have data — inputs `x` and the correct answers `y` — and you want the weights
`w` that map one to the other. You do not know them. So:

1. **Guess.** Start with `w = [0, 0, 0, 0]`.
2. **Predict.** `y_hat = w · x`
3. **Measure the error.** `e = y_hat - y`
4. **Nudge the weights** in the direction that reduces the error:
   `w[i] -= learning_rate × e × x[i]`
5. **Repeat** until the error stops shrinking.

That is the whole algorithm. The dot product in step 2 is what the accelerator
does.

### No division needed

`learning_rate` is conventionally something like 0.03 — a fraction, which implies
division or floating point.

**Make it a power of two and it becomes a shift:**

```
learning_rate = 1/32     →     w[i] -= (e × x[i]) >> 5
```

RV64M *does* have hardware division, but a shift is **one cycle and exact**. This
is standard practice in fixed-point ML, not a workaround.

---

## 3. The hard part: integer truncation kills learning

This is the interesting bit, and it cost me three attempts.

The obvious implementation **stalls.** Not "converges slowly" — **stops dead.**

```
epoch  0:  w = [3, 2, 2, 3]   loss = 83
epoch  2:  w = [4, 0, 2, 3]   loss = 39
epoch  5:  w = [4,-1, 2, 3]   loss = 17
epoch  8:  w = [4,-1, 2, 3]   loss = 17      ← stuck
epoch 11:  w = [4,-1, 2, 3]   loss = 17      ← stuck forever
```

The loss drops, plateaus well short of the answer, and then **never moves again**,
no matter how many epochs you throw at it. The true weights are `[3,-2,1,4]`; it
found `[4,-1,2,3]` and gave up.

### Why

Look at the update:

```
w[i] -= (e × x[i]) >> 5
```

Once the error `e` gets small, `(e × x[i])` becomes smaller than 32. Shift it
right by 5 and it **truncates to zero.**

The gradient is not *too small to matter* — it is **too small to represent.** The
weights stop moving because integer arithmetic cannot express "move by 0.3." The
model is stuck at whatever it happened to reach when the gradients fell below the
representable floor.

### The fix: keep the error in fixed point too

Hold the weights **and the error** in **Q8 fixed point** — everything scaled by
256, so `1.0` is stored as `256`:

```
pred_q = w_q · x                 Q8 prediction — do NOT truncate
err_q  = pred_q - (y << 8)       Q8 error
w_q[i] -= (err_q × x[i]) >> 5    Q8 gradient, Q8 weight
```

Now a gradient of "0.3" is **77** in Q8 — comfortably large enough to move a
weight. The learning does not stall.

**The critical line is the second one.** The instinct is to de-scale the
prediction back to an integer before computing the error — and that single
truncation is what breaks everything. Once `|error| < 1` rounds to `0`, the
gradient is zero and learning is over. **Keep it scaled.**

This is not a quirk of this hardware. It is the fundamental constraint of
fixed-point training, and it is why quantization-aware training is a specialty in
its own right.

---

## 4. It works

[program_train.asm](../program_train.asm) learns `w = [3, -2, 1, 4]` from four
samples, starting from nothing:

```
x0 = [1,2,1,1]  →  y = 4
x1 = [2,1,0,1]  →  y = 8
x2 = [1,0,2,1]  →  y = 9
x3 = [0,1,1,2]  →  y = 7
```

The weights are never given to the program — only the data they produced. After
**150 epochs and 600 dot products**:

```
true weights     = [3, -2, 1, 4]
software learned = [3, -2, 1, 4]
hardware learned = [3, -2, 1, 4]     ← exact
```

Zero faults. **The network inferred the function from its outputs.**

The testbench runs the *same* gradient descent independently in software and
requires the hardware to match it bit for bit — so a plausible-looking answer that
happened to be wrong would be caught.

---

## 5. Where the accelerator now stands

| Capability | Status |
|---|---|
| Packed int8 lanes (8× throughput) | done |
| Dot product, matrix multiply | done |
| DMA operand fetch (input side) | done |
| **DMA result write-back (output side)** | **done** |
| Software tiling (unbounded vector length) | done |
| Inference — linear, logistic, MLP | done |
| **Training — gradient descent** | **done** |

Both sides of the memory bottleneck are closed. The loop is complete: the
accelerator can now fetch its own data, compute, write its own results, and use
those results to improve itself.

---

## 6. What is still not done

**Training is linear regression only.** Backpropagation through the MLP's hidden
layer needs the chain rule — the gradient of the *hidden* weights depends on the
*output* weights. That is more bookkeeping, not new hardware.

**The tiling loop is manual.** Software computes the tile boundaries. A general
loop would handle any vector length; the hardware needs nothing new.

**Rungs 4–8 of [ML_POST_ROADMAP.md](ML_POST_ROADMAP.md).** KNN, K-means, CNN,
RNN, Transformer. The roadmap notes that **CNNs are a better hardware fit than
KNN** — a convolution *is* a sliding dot product, which is precisely what this
accelerator does. *(The CNN is now done — see
[ML_BLOCKS_EXPLAINED_6.md](ML_BLOCKS_EXPLAINED_6.md). Rungs 4 and 5 were skipped.)*

**The CPU still cannot trap.** No CSRs, no `ECALL`, no `mtvec`/`mepc`/`mcause`.
Faults set a flag and the PC walks straight past. This is the single biggest gap
between "correct instruction semantics" and "a CPU that could boot something," and
it is unrelated to the accelerator. See [RISCV_COMPLIANCE.md](RISCV_COMPLIANCE.md).

---

## 7. The register map, current

| Addr | idx | Register | Purpose |
|---|---|---|---|
| `0x780` | 0 | `ML_CTRL` | see below |
| `0x788` | 1 | `ML_STATUS` | `[0]`busy `[1]`done |
| `0x790` | 2 | `ML_A` | operand A — direct, or buffer append |
| `0x798` | 3 | `ML_B` | operand B — direct, or buffer append |
| `0x7A0` | 4 | `ML_ACC_LO` | result, low 64 |
| `0x7A8` | 5 | `ML_ACC_HI` | result, high 64 |
| `0x7B0` | 6 | `ML_LEN` | length in chunks, or packed M/N/K |
| `0x7B8` | 7 | `ML_SRC_A` | DMA: address of A in RAM |
| `0x7C0` | 8 | `ML_SRC_B` | DMA: address of B in RAM |
| `0x7C8` | 9 | `ML_CNT` | DMA counts — `[15:0]`=A, `[31:16]`=B |
| `0x7D0` | 10 | **`ML_DST`** | **DMA-out: where to write results** |
| `0x7F8` | — | `out_port` | debug output |

`ML_CTRL` bits:

```
  [0]    start       pulse - run the selected operation
  [1]    clear       pulse - zero the accumulator and the buffer pointers
  [2]    is_signed   level
  [4:3]  lane_mode   0=int8, 1=int16, 2=int32, 3=int64
  [6:5]  op          0=MAC, 1=DOT, 2=MAT
  [7]    dma         pulse - fetch operands from RAM
  [8]    accumulate  level - add to the existing total (tiling)
  [9]    store       pulse - write results back to RAM at ML_DST   ← new
```

**Note `ML_CNT` carries two counts.** A matrix-vector multiply needs operands of
*different lengths* — A is the weight matrix (M × k_chunks), B is a single vector
(k_chunks). A single shared count made `OP_MAT` unusable through the DMA, which is
a large part of why nothing had ever driven it. A zero B-field means "same as A,"
so dot-product programs are unaffected.

## 8. Running it

```sh
# training - the network learns w = [3,-2,1,4] from data
python tools/assembler.py program_train.asm program_train.mem
iverilog -I src -o tr.vvp src/*.v tb/tb_cpu_train.v && vvp tr.vvp

# MLP with a whole layer in one OP_MAT run
python tools/assembler.py program_mlp_mat.asm program_mlp_mat.mem
iverilog -I src -o mm.vvp src/*.v tb/tb_cpu_mlp_mat.v && vvp mm.vvp
```

**Full suite: 9,901 checks across 23 testbenches, 0 errors.**
