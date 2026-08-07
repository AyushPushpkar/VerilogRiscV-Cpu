# ML Blocks Explained, Part 4 — Scale

Continues [ML_BLOCKS_EXPLAINED_3.md](ML_BLOCKS_EXPLAINED_3.md). Same assumption:
no prior familiarity with the code.

Parts 1–3 built the accelerator and made it reachable. Part 3 ended by running
**linear regression** on it — the first real ML workload — and reported an
uncomfortable result:

> *"At 4 features the accelerator is a wash."*

This part is about what happened when we tried to make the model **bigger**, which
is what real models are. Two RTL bugs fell out, and neither could have been found
any other way.

---

## 1. Why 4 features was the wrong test

Real models are not 4 features wide:

| Workload | Features |
|---|---|
| Our first linear regression | **4** |
| A real house-price model | 10–100 |
| One layer of a small MLP | 128–1,024 |
| **MNIST digit (28×28 image)** | **784** |
| Text classifier (bag-of-words) | 1,000–50,000 |

So the 4-feature demo proved the *wiring* worked. It could not prove the
*accelerator* was worth building — and in fact it showed it wasn't, because the
memory-mapped handshake (clear, point the DMA, fire, poll, fire, poll, read) costs
about what 4 features of scalar math would.

The reason to expect a win is that these two costs **scale differently**:

- **Scalar cost is linear** in the feature count — 4 instructions per feature,
  forever.
- **Accelerator cost is flat** — the handshake is the same whether you feed it 4
  features or 4,000.

A line versus a constant. At 4 features they cross. At 784 they do not.

---

## 2. Bug #1 — the packed lanes were unreachable

Trying to scale up immediately hit something that should have been caught much
earlier.

`vec_mac` — the packed-lane engine from part 2, the 8× that this **entire
accelerator is built around** — was never being used by the dot-product path.

`dot_product` wrapped the **scalar `mac_unit`**, not `vec_mac`. It had no
`lane_mode` port at all:

```verilog
mac_unit #(...) u_mac (        // <-- SCALAR. One element per cycle.
    .clk (clk), .en (mac_en), .is_signed (sign_q),
    .a (a_data), .b (b_data), .acc (result)
);
```

So `OP_DOT` ran **one element per cycle regardless of what lane mode software
asked for.** Setting `LANE_8` did nothing. The packed lanes were simply not
plumbed into the dot product.

And nobody noticed, because **every program written up to that point ran
`LANE_64`.** The 8× the whole design exists to deliver had never once been
exercised by a real workload. It was tested in isolation (`tb_vec_mac`) and
correct in isolation — and unreachable in practice.

### The fix

Rewire `dot_product` to instantiate `vec_mac` and thread `lane_mode` through from
`ml_accel`. One consequence, and it matters:

> **`vec_len` now counts CHUNKS, not elements.**

A "chunk" is one 64-bit operand word. At `LANE_8` a chunk holds **8 packed int8
values**, so a 64-element vector is **8 chunks**. At `LANE_64` a chunk is one
element and the old meaning is unchanged.

### The test that broke — and should have

`tb_dot_product` immediately failed 3 checks. It had been leaving `lane_mode`
unconnected, which defaults to `0` — which is `LANE_8` — so its 64-bit test values
were suddenly being reinterpreted as 8 packed bytes each.

That is the testbench doing its job: a silent semantic change got caught loudly.
Fixed by driving `LANE_64` explicitly, which is what those tests always meant.

---

## 3. What packing actually buys

With the lanes reachable, a **64-feature** linear regression
([program_linreg8.asm](../program_linreg8.asm)):

```
w = [(i%7)-3 for i in 0..63]     weights, -3..3
x = [(i%5)+1 for i in 0..63]     features, 1..5
b = 100

w·x = -15   ->   y = 85
```

Measured on hardware: **64 features in 8 cycles.** 31 instructions total, against
~260 for the scalar equivalent.

The int8 packing pays **three times over**:

| | int64 | int8 packed |
|---|---|---|
| **Storage** per vector | 512 bytes | **64 bytes** |
| **DMA** doublewords | 64 | **8** |
| **Compute** cycles | 64 | **8** |

Same features, an eighth of everything. That is what the lanes were for.

---

## 4. Bug #2 — the buffer was a ceiling, not a granularity

Then we tried 784 features. And hit a wall that was not obvious from the outside.

The operand buffer holds **64 chunks**. At `LANE_8` that is 512 features. **784
does not fit.**

The standard answer is **tiling**: split the vector, run it in pieces, add the
pieces up.

```
   784 features = 98 chunks

   tile 0:  chunks  0..63   (512 features)   ->  partial sum
   tile 1:  chunks 64..97   (272 features)   ->  add to it
                                                 -----------
                                                 full result
```

But this did not work, and the reason was in the RTL:

```verilog
wire mac_clear = (state == S_IDLE) && start;   // ALWAYS clears
```

**`dot_product` zeroed the accumulator on every `start`.** So tile 1 wiped tile
0's partial sum. There was no way to accumulate across runs.

That made the buffer size a **hard ceiling on model size** — you could not run
anything bigger than 512 int8 features, full stop.

### The fix

An `accumulate` input, exposed as **`ML_CTRL[8]`**:

```verilog
wire mac_clear = (state == S_IDLE) && start && !accumulate;
```

When set, a run **adds into the existing total** instead of zeroing it.

### Why this is better than doing it in software

You could imagine software reading the partial sum after each tile and adding it
back. That would work — and it would be worse:

- The accumulator is **128 bits**. A CPU register is **64**. Round-tripping the
  partial sum through software **throws away the top half** — precisely the
  headroom the widened accumulator exists to provide.
- It costs instructions per tile, which is the cost we are trying to avoid.

Keeping the accumulation **inside the accelerator** means partial sums are never
rounded and never truncated. This is the whole reason part 1 insisted the
accumulator be wider than the operands.

---

## 5. MNIST scale, running

[program_mnist.asm](../program_mnist.asm) — 784 features, two tiles:

```
[195 ns]  tile 0: DMA fetch
[1535 ns] tile 0: dot start (accumulate=0)
[2195 ns]   running total = -7          <- 512 features
[2315 ns] tile 1: DMA fetch
[3055 ns] tile 1: dot start (accumulate=1)
[3415 ns]   running total = 1           <- + 272 more features
[3655 ns] halt

Dot MAC cycles = 98    (64 + 34, exactly as expected)
out_port       = 1001  (w·x = 1, plus bias 1000)
Faults         = none
```

You can watch the tiling work: tile 0 produces −7, tile 1 **adds** its
contribution to reach 1 — matching the software model exactly.

**98 MAC cycles for 784 features. 48 instructions against ~3,136 scalar.**

The buffer size is now a **tiling granularity**, not a model-size limit. A vector
of any length runs; it just takes more tiles.

---

## 6. The three programs, and why each one mattered

| Program | Features | What it proved | What it hid |
|---|---|---|---|
| `program_linreg` | 4 | The hardware works | That the lanes were unreachable |
| `program_linreg8` | 64 | Packed lanes: 8× | That tiling was impossible |
| `program_mnist` | **784** | Tiling: unbounded length | — |

**Each step up in scale found a bug the previous step could not.** Neither was
visible in unit tests — `vec_mac` was correct in isolation, `dot_product` was
correct in isolation. They were wrong *together*, and only a workload big enough
to care would ever show it.

That is the lesson worth keeping from this part:

> **Unit tests prove a block is correct. Only a real workload at real scale
> proves the system is.**

---

## 7. Cost, honestly

```
                    4 feat    64 feat    784 feat
  scalar             ~20       ~260       ~3136      instructions
  accelerator        ~17        ~31         ~48      instructions
  speedup            1.2x       8.4x        65x
```

The accelerator column barely moves. That is the design working exactly as
intended — and it is why the 4-feature demo was misleading rather than wrong.

At `LANE_8` the compute is 8× faster on top of the instruction-count win, and the
DMA fetches 8 features per cycle rather than 1.

---

## 8. Climbing the workload ladder

[ML_POST_ROADMAP.md](ML_POST_ROADMAP.md) ranks ML workloads from easiest to
hardest. Rungs 1–3 now run on this hardware.

**Note that none of them required new RTL.** Everything from here is software on
hardware that already exists — which is the sign the accelerator is finished.

### Rung 2: logistic regression — the integer sigmoid

Binary classification. The dot product is **identical** to linear regression; the
only new thing is turning `z` into a probability:

```
z = w · x + b        ← accelerator, unchanged
y = sigmoid(z)       ← new
```

**The problem:** `sigmoid(z) = 1/(1 + e^-z)` needs floating point and `exp()`.
This CPU has neither — it is RV64IM, no `F` extension.

And it is worth being clear that **no ISA has `exp()`**. Not RISC-V, not ARM, not
x86. `exp`, `log`, `sin` are always *software* polynomial approximations, costing
dozens of instructions even on a machine with an FPU.

**Two observations make it tractable:**

**1. The classification is free.**

```
sigmoid(z) > 0.5   ⟺   z > 0
```

So the class label is a **sign test** on the accelerator's output. No sigmoid
needed at all. This holds on *any* hardware, FPU or not — which is why logistic
regression is barely harder than linear regression on an integer machine.

**2. The probability comes from a lookup table.**

Sigmoid precomputed at integer `z ∈ [-8, +8]`, stored as **Q8 fixed point**
(256 = 1.0). Outside that range sigmoid is within 0.04% of 0 or 1, so `z` is
simply clamped. Inference = clamp, index, load.

```
LUT: [0, 0, 1, 2, 5, 12, 31, 69, 128, 187, 225, 244, 251, 254, 255, 256, 256]
      ↑ z=-8                    ↑ z=0                              ↑ z=+8
```

**This is not a workaround for a weak CPU — it is what production quantized ML
actually does.** TensorFlow Lite, ARM CMSIS-NN, and most NPUs compute sigmoid and
tanh via integer LUTs or piecewise-linear approximations, because FP is slower,
burns more power, and int8 inference does not need the precision.

[program_logreg.asm](../program_logreg.asm) classifies 4 samples:

```
x0: z = +4  →  class 1,  P = 251/256  (0.98)
x1: z = -5  →  class 0,  P =   2/256  (0.01)
x2: z = +1  →  class 1,  P = 187/256  (0.73)
x3: z = -1  →  class 0,  P =  69/256  (0.27)
```

The samples are chosen so **every `z` lands inside the table** — the LUT is
genuinely exercised, not just clamped at the rails. The program publishes the
**sum of probabilities** (509) rather than the class count, because that depends
on every lookup being right, not merely on the sign of each `z`.

### Rung 3: a 2-layer MLP — a real neural network

```
4 inputs  →  3 hidden (ReLU)  →  1 output

hidden = ReLU(W1 · x)        3 dot products
y      = W2 · hidden + b2    1 dot product
```

**Each layer is a matrix-vector multiply.** That is all a neural network *is* —
the "deep" part is just doing this repeatedly.

**The activation is ReLU, not sigmoid:**

```
ReLU(x) = max(0, x)
```

On integer hardware that is **a single branch.** No lookup table, no floating
point, nothing. This is genuinely why ReLU won over sigmoid in practice: it is
almost free. Logistic regression needed a LUT; an MLP does not.

**What is structurally new:** the hidden layer's output becomes layer 2's
**input**. The program packs the three hidden values back into RAM as int8 so the
DMA can fetch them — **the first workload where an accelerator result
round-trips into an accelerator operand.** That is what makes it a *network*
rather than a single layer.

[program_mlp.asm](../program_mlp.asm):

```
hidden 0: W1·x =  +7  →  ReLU →  7
hidden 1: W1·x = -10  →  ReLU →  0    ← the activation actually FIRES
hidden 2: W1·x =  +2  →  ReLU →  2

hidden = [7, 0, 2]
y = 2·7 + (-1)·0 + 3·2 + 5 = 25
```

The weights are deliberately chosen so **ReLU fires** — neuron 1 goes negative
and gets clamped. Without the activation the answer would be **35**, and the
testbench checks for that value *by name* and reports "activation skipped" if it
sees it. A test where the activation never triggers would prove nothing.

One small detail worth knowing: a 4-element vector safely occupies an 8-lane int8
chunk because **the unused lanes are zero, and `0 × 0 = 0`** contributes nothing
to the dot product. Zero-padding is free.

### The ladder

| Rung | Workload | Status |
|---|---|---|
| 1 | Linear regression | done — 784 features, 65× |
| 2 | Logistic regression | done — integer sigmoid LUT |
| 3 | Perceptron / small MLP | done — ReLU, layer chaining |
| 4 | KNN | distance kernels |
| 5 | K-means | KNN + centroid updates |
| 6 | Small CNN | convolution = sliding dot product |
| 7–8 | RNN, Transformer | — |

The roadmap notes that **CNNs are a better hardware fit than KNN** — a convolution
*is* a sliding dot product, which is exactly what this accelerator does. Rungs 4
and 5 could reasonably be skipped.

---

## 9. What is still not done

> **All three of the gaps below have since been closed.** See
> [ML_BLOCKS_EXPLAINED_5.md](ML_BLOCKS_EXPLAINED_5.md): DMA write-back, training
> by gradient descent, and `OP_MAT` driving a whole MLP layer.

**Only inference, not training.** *(Now done — part 5.)* Gradient descent needs
division (which RV64M has) and multiple passes. This is a software problem, not a
hardware gap.

**Tiling is manual.** Software computes the tile boundaries and issues the runs.
A loop would generalize it; the hardware needs nothing new.

**The DMA reads but does not write.** *(Now done — part 5.)* Results still come
back through `ML_ACC_LO` one load at a time. For a large output matrix that is the
next bottleneck, and a DMA-out path would reuse the same machinery.

**`matrix_tile` is still not used by any workload.** *(Now fixed.)* The MLP does
its layers as *separate dot products* rather than one matrix-vector multiply.
`OP_MAT` works and is tested, but no real program drives it — the same trap the
packed lanes were in before part 4 found them.

> **And it hid a bug, exactly as predicted.** Driving `OP_MAT` from a real
> program exposed that the DMA had a **single shared operand count** — but a
> matrix-vector multiply needs A (the weight matrix, M × k_chunks) and B (a
> single vector, k_chunks) at *different lengths*. `OP_MAT` was **unusable
> through the DMA**, which is a large part of *why* nothing had ever driven it.
> The unused hardware and the bug were causally linked.
>
> `ML_CNT` now carries two counts. And the payoff is the same flat-vs-linear
> story as the packed lanes: the MMIO handshake is paid **per run**, and `OP_DOT`
> needs one run *per neuron* while `OP_MAT` needs one *per layer* — **13× fewer
> instructions at 128 neurons.** See [program_mlp_mat.asm](../program_mlp_mat.asm).

**The CPU is still not privileged-spec compliant** — no traps, no CSRs, no
`ECALL`. Unrelated to the accelerator, but it bounds what this system can be. See
[RISCV_COMPLIANCE.md](RISCV_COMPLIANCE.md).

---

## 10. The register map, current

| Addr | idx | Register | Purpose |
|---|---|---|---|
| `0x780` | 0 | `ML_CTRL` | see below |
| `0x788` | 1 | `ML_STATUS` | `[0]`busy `[1]`done |
| `0x790` | 2 | `ML_A` | operand A — direct, or buffer append |
| `0x798` | 3 | `ML_B` | operand B — direct, or buffer append |
| `0x7A0` | 4 | `ML_ACC_LO` | result, low 64 |
| `0x7A8` | 5 | `ML_ACC_HI` | result, high 64 |
| `0x7B0` | 6 | `ML_LEN` | length in **chunks**, or packed M/N/K |
| `0x7B8` | 7 | `ML_SRC_A` | DMA: address of A in RAM |
| `0x7C0` | 8 | `ML_SRC_B` | DMA: address of B in RAM |
| `0x7C8` | 9 | `ML_CNT` | DMA: doublewords per operand |
| `0x7F8` | — | `out_port` | debug output |

`ML_CTRL` bits:

```
  [0]    start       pulse - run the selected operation
  [1]    clear       pulse - zero the accumulator and the buffer pointers
  [2]    is_signed   level
  [4:3]  lane_mode   0=int8, 1=int16, 2=int32, 3=int64
  [6:5]  op          0=MAC, 1=DOT, 2=MAT
  [7]    dma         pulse - fetch operands from RAM
  [8]    accumulate  level - add to the existing total (TILING)   <-- new
```

## 11. Running it

```sh
# 64 features, packed int8
python tools/assembler.py program_linreg8.asm program_linreg8.mem
iverilog -I src -o lr8.vvp src/*.v tb/tb_cpu_linreg8.v && vvp lr8.vvp

# 784 features, tiled
python tools/assembler.py program_mnist.asm program_mnist.mem
iverilog -I src -o mn.vvp src/*.v tb/tb_cpu_mnist.v && vvp mn.vvp

# logistic regression - binary classification, integer sigmoid
python tools/assembler.py program_logreg.asm program_logreg.mem
iverilog -I src -o lg.vvp src/*.v tb/tb_cpu_logreg.v && vvp lg.vvp

# 2-layer MLP - a neural network
python tools/assembler.py program_mlp.asm program_mlp.mem
iverilog -I src -o mlp.vvp src/*.v tb/tb_cpu_mlp.v && vvp mlp.vvp
```

**Full suite: 9,901 checks across 21 testbenches, 0 errors.**
