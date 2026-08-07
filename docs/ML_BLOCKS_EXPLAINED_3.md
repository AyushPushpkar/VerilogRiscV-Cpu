# ML Blocks Explained, Part 3

Continues [ML_BLOCKS_EXPLAINED_2.md](ML_BLOCKS_EXPLAINED_2.md). Same assumption:
no prior familiarity with the code.

Parts 1 and 2 built the arithmetic. This part covers the two pieces that finish
the accelerator:

- `src/matrix_tile.v` — matrix multiply (GEMM), the last block in the roadmap
- `src/ml_accel.v` — rewritten, so **all three engines are now reachable from
  software**

This closes the limitation part 2 ended on. The engines are no longer stranded.

---

## 1. Where part 2 left off

Part 2 ended with an honest admission: `dot_product` and `matrix_tile` were
**verified but unreachable**. Only `vec_mac` was exposed through memory-mapped
I/O, so software had to run the accumulate loop itself — three stores per
eight elements, over and over.

That is a strange place to be. You have hardware that can run a whole vector
dot product autonomously, and instead the CPU is hand-feeding it one chunk at a
time. The hardware exists; nothing can call it.

Two things fix that, and they are what this part is about.

---

## 2. `matrix_tile.v` — GEMM

### What it computes

```
C = A x B        for  A[M x K] * B[K x N]  ->  C[M x N]
```

### The key insight: this block does no arithmetic

Matrix multiply looks intimidating, but it decomposes into something already
built:

```
C[i][j] = A[i][0]*B[0][j] + A[i][1]*B[1][j] + ... + A[i][K-1]*B[K-1][j]
          \_________________________________________________________/
                   this is just a DOT PRODUCT
```

**Every element of C is a dot product** — of row `i` of A against column `j` of
B. So matrix multiply is: *do a dot product, M×N times.*

That means `matrix_tile` is **orchestration, not arithmetic.** It walks three
counters (`i`, `j`, `k`) and feeds `vec_mac`, which does the actual work. It
never contains a multiplier. This is exactly what
[ML_ACCELERATOR_DESIGN.md](ML_ACCELERATOR_DESIGN.md) means by "matrix ops are
mostly orchestration around vector MACs" — and it is why the block is short.

### Why it reuses `vec_mac`, not `mac_unit`

Because packing still pays. At `LANE_8`, one accumulate step consumes **eight
elements of the k dimension at once**. So the `k` counter advances by the lane
count, not by 1:

```
k_idx = 0  ->  A[i][0..7]  ·  B[0..7][j]     one cycle, 8 MACs
k_idx = 8  ->  A[i][8..15] ·  B[8..15][j]    one cycle, 8 more
```

A K=8 inner product is **one cycle**, not eight. If it reused the scalar
`mac_unit`, the whole 8× advantage from part 2 would be thrown away at exactly
the point where it matters most.

### Tile boundaries: what happens when K isn't a multiple of 8

This is the case that breaks naive implementations. If K = 7, the last chunk
only has 7 real elements and one leftover lane. If K = 9, you need two chunks
and the second is almost empty.

The block handles this by **not caring**. Whoever supplies operands zeroes the
lanes past `K`, and a zero lane contributes `0 × 0 = 0` to the sum — it is
arithmetically invisible. The testbench covers K = 1, 7, 8, 9, and 12 for
exactly this reason.

### The streaming interface

Like `dot_product`, it does not hold the matrices. It drives `row`, `col`, and
`k_idx`, and expects the corresponding packed chunks back the same cycle:

```
matrix_tile  --- row, col, k_idx --->  [operand source]
             <-- a_data, b_data -----
```

**Results stream out** the same way: `c_valid` pulses once per output element,
with `c_row`/`c_col` identifying it. No local C storage — the consumer writes it
wherever C lives. Both choices keep the block independent of whether the data
sits in RAM, a scratchpad, or MMIO buffers.

### The bug worth knowing about

The first version produced **all zeros** — while iterating perfectly. Every
element emitted, right order, right indices, all zero.

The trace showed why. In the `S_EMIT` state the accumulator correctly held 42,
but `mac_clear` was *also* high in that state — and `c_valid` was **registered**,
so it pulsed one cycle later, by which point the accumulator had already been
wiped:

```
t=36  state=EMIT  acc=42  clear=1  c_valid=0    <- value is right, not published
t=46  state=DONE  acc=0   clear=0  c_valid=1    <- published, but acc is gone
```

Fixed by asserting `c_valid` **combinationally** in `S_EMIT`, so the pulse and
the valid data land in the same cycle.

**This is the same class of bug as `dot_product`'s `mac_en` in part 1.** Hold
that thought — it happens a third time below.

---

## 3. `ml_accel.v` — making everything reachable

The problem, stated plainly.

`dot_product` and `matrix_tile` **stream** operands: they drive an index and
expect the data back **in the same cycle**, one element per clock.

The CPU cannot do that. It executes one instruction at a time, and a load *is* a
whole instruction. By the time software fetched, decoded, and executed a load to
supply element 0, the engine would need element 5.

### The fix: give the accelerator its own buffer

Software fills an operand buffer **first**. Then it starts the engine, which
reads that buffer at full speed with no CPU involvement.

```
   software                     accelerator
   --------                     -----------
   fill buffer  ------------->  buf_a[0..N], buf_b[0..N]
   write start  ------------->  engine reads buffer at 1 element/cycle
   poll status  <-------------  busy / done
   read result  <-------------  C
```

### Why the buffer has one address, not N

Here is a real constraint that shaped the design.

`reg_idx` is **3 bits** — it comes from address bits `[5:3]`. That is **8
register slots total**, and `out_port` owns one. There was never room to expose
one address per buffer entry; a 64-entry buffer would need 64 addresses.

So the buffer is written through **one register with an auto-incrementing
pointer**:

```
store ML_A <- a[0]     # appends, pointer -> 1
store ML_A <- a[1]     # appends, pointer -> 2
store ML_A <- a[2]     # appends, pointer -> 3
```

Each write appends one entry and advances. One address, N entries. Writing
`clear` to `ML_CTRL` resets the pointer so a new problem starts from entry 0.

Constraints like this are worth noticing: the *elegant* solution here was forced
by an address budget, not chosen for beauty.

### The register map

| Addr | idx | Register | R/W | Purpose |
|---|---|---|---|---|
| `0xC0` | 0 | `ML_CTRL` | W | start / clear / signed / lanes / **op** |
| `0xC8` | 1 | `ML_STATUS` | R | `[0]`=busy `[1]`=done |
| `0xD0` | 2 | `ML_A` | W | operand A — direct value, or buffer append |
| `0xD8` | 3 | `ML_B` | W | operand B — direct value, or buffer append |
| `0xE0` | 4 | `ML_ACC_LO` | R | result, low 64 bits |
| `0xE8` | 5 | `ML_ACC_HI` | R | result, high 64 bits |
| `0xF0` | 6 | **`ML_LEN`** | W | **new** — vector length, or packed M/N/K |
| `0xF8` | — | `out_port` | W | debug output (not part of the accelerator) |

`ML_CTRL` bit layout:

```
  [0]    start      pulse - run the selected operation
  [1]    clear      pulse - zero the accumulator AND reset the fill pointer
  [2]    is_signed  level
  [4:3]  lane_mode  level - 0=int8, 1=int16, 2=int32, 3=int64
  [6:5]  op         level - 0=MAC, 1=DOT, 2=MAT       <-- NEW
```

### Three modes

| `op` | Mode | Engine | What one `start` does |
|---|---|---|---|
| 0 | `OP_MAC` | `vec_mac` | one packed multiply-accumulate |
| 1 | `OP_DOT` | `dot_product` | **an entire vector dot product** |
| 2 | `OP_MAT` | `matrix_tile` | **an entire matrix multiply** |

`OP_MAC` is the part-2 behavior, unchanged — the old software still works.

### Software recipe: dot product

```
store ML_CTRL <- clear
store ML_A    <- a[0], a[1], ... a[n-1]     # buffer fills, pointer advances
store ML_B    <- b[0], b[1], ... b[n-1]
store ML_LEN  <- n
store ML_CTRL <- start | signed | OP_DOT    # ONE store runs the whole loop
poll  ML_STATUS until done
load  ML_ACC_LO                              # the answer
```

### Software recipe: matrix multiply

Same shape, plus dimensions packed into `ML_LEN` (`[7:0]`=M, `[15:8]`=N,
`[23:16]`=K):

```
store ML_CTRL <- clear
store ML_A    <- A, row-major
store ML_B    <- B, COLUMN-major          # see below
store ML_LEN  <- (K << 16) | (N << 8) | M
store ML_CTRL <- start | signed | OP_MAT
poll  ML_STATUS until done
load  ML_ACC_LO  repeatedly               # walks C in row-major order
```

**Why B is stored column-major:** `C[i][j]` needs *column* `j` of B. In row-major
storage a column is strided — you'd have to gather it element by element. Store B
transposed and the column becomes contiguous, so it is a simple indexed read.
`matrix_tile` deliberately pushes this to the caller rather than building a
gather engine.

**Reading C back:** in `OP_MAT`, each `ML_ACC_LO` load **advances a read
pointer**, so repeated loads walk the result matrix. Same trick as the write
buffer, same reason: no address space to spare.

---

## 4. The proof: a GEMM running on the CPU

[program_mat.asm](../program_mat.asm) computes:

```
A = [1 2]   B = [5 6]   C = A x B = [19 22]
    [3 4]       [7 8]               [43 50]
```

and publishes `sum(C)` = 19+22+43+50 = **134** — a single value that can only be
right if all four elements are right.

The trace from [tb_cpu_mat.v](../tb/tb_cpu_mat.v):

```
[335 ns] GEMM started (one store)
[365 ns]   engine emitted C[0][0] = 19
[395 ns]   engine emitted C[0][1] = 22
[425 ns]   engine emitted C[1][0] = 43
[455 ns]   engine emitted C[1][1] = 50
[475 ns] GEMM done
out_port = 134
```

Look at what that shows: software issues **one store**, and the hardware produces
the entire matrix by itself. Compare to part 2, where software had to issue three
stores per eight elements and drive the loop by hand.

---

## 5. The same bug, a third time

The GEMM program **hung**, spinning in its poll loop forever. `ML_STATUS` never
reported done — because the engine had never started.

`mat_start` was defined as:

```verilog
wire mat_start = start_pulse && (op_reg == OP_MAT);
```

`start_pulse` is combinational — it is high on the exact cycle the CPU's store to
`ML_CTRL` lands. But `op_reg` is **registered** by that *same* store. So on the
cycle `start_pulse` is high, `op_reg` still holds the **previous** op. It does not
become `OP_MAT` until the next clock edge, by which time `start_pulse` is gone.

The start pulse and the op select were never true at the same time. The engine
was never selected.

Fixed by decoding the op from the **write data** rather than the register:

```verilog
wire [1:0] op_now = ctrl_write ? wdata[6:5] : op_reg;
wire mat_start = start_pulse && (op_now == OP_MAT);
```

### The pattern

This is the **third** instance of the same bug in this codebase:

| Where | What was misaligned |
|---|---|
| `dot_product.v` (part 1) | registered `mac_en` vs. combinational operands |
| `matrix_tile.v` (part 3) | registered `c_valid` vs. combinationally-cleared `acc` |
| `ml_accel.v` (part 3) | registered `op_reg` vs. combinational `start_pulse` |

Every one of them: **a registered value used alongside a combinational signal
that changes in the same cycle.** The register is always one cycle behind.

The rule, now written into the RTL comments:

> **A registered value must not gate a combinational pulse derived from the same
> write. A qualifier and the data it qualifies must be asserted in the same
> cycle.**

If you write more streaming hardware in this codebase, this is the bug you will
write. Look for it first.

---

## 6. Roadmap: complete

From [ML_RTL_IMPLEMENTATION_ORDER.md](ML_RTL_IMPLEMENTATION_ORDER.md):

| Step | Status |
|---|---|
| 1. Testbench reference models | done — `tb_ml_ref.v` |
| 2. Standalone MAC RTL | done — `mac_unit.v` |
| 3. Dot-product control | done — `dot_product.v` |
| 4. Packed vector lanes | done — `vec_mac.v` |
| 5. Horizontal reduction | done — folded into `vec_mac.v` |
| 6. Matrix-tile controller | **done** — `matrix_tile.v` |
| — CPU integration | **done** — all three engines reachable |

**All six RTL steps are complete, and every engine is driveable from software.**

## 7. Test suite

| Testbench | Checks |
|---|---|
| `tb_matrix_tile` | 84 |
| `tb_ml_accel_ops` (DOT + MAT modes) | 21 |
| `tb_ml_accel` (OP_MAC regression) | 15 |
| `tb_vec_mac` | 15 |
| `tb_mac` | 31 |
| `tb_dot_product` | 13 |
| `tb_ml_ref` | 5 |
| `tb_cpu_mat` | GEMM on real hardware |
| `tb_cpu_ml` | dot product on real hardware |

Plus the RISC-V compliance suite — see
[RISCV_COMPLIANCE.md](RISCV_COMPLIANCE.md).

**Total: 9,895 checks across 15 testbenches, 0 errors.**

```sh
# matrix tile block
iverilog -I src -o mat.vvp src/vec_mac.v src/matrix_tile.v tb/tb_matrix_tile.v
vvp mat.vvp

# DOT and MAT modes through the bus
iverilog -I src -o ops.vvp src/vec_mac.v src/mac_unit.v src/dot_product.v \
    src/matrix_tile.v src/ml_accel.v tb/tb_ml_accel_ops.v && vvp ops.vvp

# GEMM on the real CPU
python tools/assembler.py program_mat.asm program_mat.mem
iverilog -I src -o cpumat.vvp src/*.v tb/tb_cpu_mat.v && vvp cpumat.vvp
```

---

## 8. The DMA — feeding the beast

Everything above made the *compute* fast. This section is about the fact that
**fast compute you cannot feed is useless.**

### The measurement

[ML_ACCELERATOR_DESIGN.md](ML_ACCELERATOR_DESIGN.md) §8 predicted the problem:

> *"ML speed is often limited by memory, not arithmetic. Without this, the
> accelerator will stall waiting on scalar memory traffic."*

It was right, and it is measurable. In the 2×2 GEMM above:

| | cycles |
|---|---|
| The GEMM engine actually computing | **14** |
| The whole program | **76** |

**The accelerator sat idle 82% of the time.** The other 62 cycles were software
shovelling 8 operands into the buffer, one `SD` per element, plus building
constants.

And it gets worse with scale. The feeding cost grows with the data; the compute
does not. An 8×8 GEMM needs 128 operand stores to feed an engine that computes it
in ~70 cycles.

### The fix: let the accelerator read memory itself

A **DMA** (Direct Memory Access) engine. Instead of software pushing operands in
one at a time, the accelerator is told *where the data lives* and fetches it
itself:

```
   software                          accelerator
   --------                          -----------
   "A is at 0x000"     ----------->  ML_SRC_A
   "B is at 0x040"     ----------->  ML_SRC_B
   "there are 8 each"  ----------->  ML_CNT
   "go"                ----------->  ML_CTRL[7]
                                          |
                                          v
                       DMA reads RAM at 1 doubleword/cycle,
                       filling buf_a and buf_b by itself
```

**Filling a 64-entry buffer drops from 64 store instructions to 4** — and that
cost is now **constant**, not proportional to the vector length. That is the
whole point.

### The second memory port

`data_memory` gained a second, **read-only** port for the DMA. This is cheaper
than it sounds:

- The memory is **asynchronous-read**, so a second port is just another
  combinational view of the same array — no extra storage, no write path.
- **No arbitration is needed.** The accelerator only reads while it is busy, and
  the CPU is stalled polling `ML_STATUS` during that entire window. They never
  actually contend.

(One caveat for later: async-read dual-port memory does *not* map to FPGA block
RAM. On real hardware this would need converting to a synchronous read, which
makes loads take two cycles. Fine in simulation; a real cost if you ever
synthesize.)

### RAM widened to 2 KB

The DMA reads matrices out of RAM — so the RAM has to be big enough to *hold*
them. It wasn't:

| | old | new |
|---|---|---|
| `DATA_ADDR_WIDTH` | 8 | **11** |
| Total | 256 B | **2048 B** |
| Usable RAM | 192 B | **1920 B** |

192 bytes could not hold even a **4×4** GEMM (384 B). That is why the demo was
2×2 — it was *sized to fit*, not chosen. At 2 KB an 8×8 int8 GEMM fits
comfortably.

Note what dominates: **the output matrix C**. Operands can be packed int8 (8 per
doubleword), but C holds *accumulated* values — the whole point of the widened
accumulator — so it stays 8 bytes per element. An 8×8 int8 GEMM costs 64+64 bytes
of operands and **512 bytes of output.**

### The new memory map

```
   0x000 - 0x77F    data RAM (1920 bytes)
   0x780 - 0x7F7    ML accelerator - 16 registers, 8 bytes apart
   0x7F8            out_port
```

Widening the space also relieved the register squeeze from §3: the ML block now
has **16 slots** (decode on `addr[6:3]`) instead of 8, so the DMA gets proper
registers instead of being bit-packed into `ML_LEN`'s spare bits.

| Addr | idx | Register | Purpose |
|---|---|---|---|
| `0x780` | 0 | `ML_CTRL` | `[0]`start `[1]`clear `[2]`signed `[4:3]`lanes `[6:5]`op **`[7]`dma** |
| `0x788` | 1 | `ML_STATUS` | `[0]`busy `[1]`done |
| `0x790` | 2 | `ML_A` | operand A — direct, or buffer append |
| `0x798` | 3 | `ML_B` | operand B — direct, or buffer append |
| `0x7A0` | 4 | `ML_ACC_LO` | result, low 64 |
| `0x7A8` | 5 | `ML_ACC_HI` | result, high 64 |
| `0x7B0` | 6 | `ML_LEN` | vector length, or packed M/N/K |
| `0x7B8` | 7 | **`ML_SRC_A`** | DMA: address of A in RAM |
| `0x7C0` | 8 | **`ML_SRC_B`** | DMA: address of B in RAM |
| `0x7C8` | 9 | **`ML_CNT`** | DMA: doublewords to fetch per operand |
| `0x7F8` | — | `out_port` | debug output |

A detail worth noticing: every address still fits `ADDI`'s **12-bit signed
immediate** (max 2047 — `out_port` is 2040). That is *why* the block sits at the
top of the space rather than the bottom. One instruction to load any of them.

### The proof

[program_dma.asm](../program_dma.asm) computes an 8-element dot product where the
operands already live in RAM. Software issues **zero operand stores**:

```
[435 ns] DMA triggered by ONE store
[455 ns]   DMA -> buf_a[0] = 1
[465 ns]   DMA -> buf_a[1] = 2
   ...                            16 elements, one per cycle
[605 ns]   DMA -> buf_b[7] = 2
[685 ns] dot product started
[785 ns] dot product done
out_port = 72
```

### The bug, a fourth time

The first DMA returned `buf_a = [2,3,4,5,6,7,8,2]` instead of `[1..8]` — element
0 dropped, everything shifted by one, and the last slot picked up B's first
value.

`dma_wr_en` was **registered**, so the buffer write fired one cycle *after* the
state asserted it — by which point `dma_addr` had already advanced and
`dma_rdata` held the next element. The trace made it obvious:

```
t=446  addr=0x000  rdata=1  wr_en=0     <- data is right, write not armed
t=456  addr=0x008  rdata=2  wr_en=1     <- write fires, but data moved on
```

`dma_addr` is registered and `dma_rdata` is asynchronous, so the data for
`dma_addr` is valid **in the same cycle**. Fixed by driving the write controls
combinationally from the state.

**This is the fourth instance of the same bug** — and the most instructive,
because §5 of this very document already warned about it and I walked into it
anyway. The rule holds:

> **A qualifier and the data it qualifies must be asserted in the same cycle.**

---

## 9. What is still not done

Being straight about the remaining gaps, as in the previous parts:

**The buffer is still 64 entries per operand.** The DMA fills it fast, but it
does not make it bigger. `OP_MAT` is limited to roughly an 8×8 problem; larger
matrices need tiling in software — feed one tile, accumulate, feed the next.

> **Fixed for dot products in part 4.** Tiling turned out to be *impossible* at
> the time this was written: `dot_product` cleared the accumulator on every
> `start`, so tile 2 wiped tile 1. An `accumulate` control (`ML_CTRL[8]`) fixes
> it, and 784-feature vectors now run. `OP_MAT` could use the same mechanism.

**The DMA reads, but does not write.** Results still come back through
`ML_ACC_LO` one load at a time. For a large C that is the new bottleneck. A
write path (DMA-out) is the symmetric fix and would reuse the same machinery.

**A and B are fetched in sequence, not in parallel** — there is only one memory
read port. A second would halve the DMA latency. Not obviously worth it: at one
element per cycle the DMA is already far faster than software can issue stores.

**The CPU is not privileged-spec compliant** — no traps, no CSRs, no `ECALL`.
Unrelated to the accelerator, but it bounds what this system can be. See
[RISCV_COMPLIANCE.md](RISCV_COMPLIANCE.md).

---

## 10. A real ML workload: linear regression

Everything up to here was synthetic vectors and toy matrices. This is the first
thing anyone would actually call machine learning.

### What it computes

**Inference** with a pre-trained linear model:

```
y = w · x + b          a dot product, plus a bias
```

That's the entire model. Every prediction is **one dot product** — precisely what
the accelerator does in a single `start`. This is why
[ML_POST_ROADMAP.md](ML_POST_ROADMAP.md) ranks linear regression first: *"mostly
dot products and scalar math, small code size, easy to verify."*

(Training — gradient descent — is a harder ask: it needs division and repeated
passes over the data. Inference is the honest first target.)

### The program

[program_linreg.asm](../program_linreg.asm) runs a trained 4-feature model over a
batch of 4 samples:

```
w = [3, -2, 5, 1]     b = 10

x0 = [1,2,3,4]  ->  w·x = 18  ->  y = 28
x1 = [2,0,1,5]  ->  w·x = 16  ->  y = 26
x2 = [0,4,2,1]  ->  w·x =  3  ->  y = 13
x3 = [5,5,0,0]  ->  w·x =  5  ->  y = 15
                                  ----
                sum of predictions  82
```

Negative weights are deliberate — sign handling through the packed lanes is
exactly the sort of thing that silently breaks.

**The loop is the interesting part.** Each iteration re-points the DMA at the next
sample and fires one dot product. **The weight vector never moves.** It sits in
RAM and the DMA re-fetches it every iteration at zero software cost — which is
the shape every real batched inference workload has.

The testbench checks **each individual prediction**, not just the total. A right
sum built from wrong parts would otherwise sail through.

### What it actually bought — honestly

This is where it would be easy to oversell, so here are the real numbers:

| | 4 features | 64 features |
|---|---|---|
| **Scalar** (LD, LD, MUL, ADD per element) | ~20 instr | ~260 instr |
| **Accelerator** (MMIO handshake + DMA + dot) | ~17 instr | **~17 instr** |

**At 4 features the accelerator is a wash.** The MMIO handshake — clear, point the
DMA, fire, poll, fire, poll, read — costs about what the scalar math would have.

The win is that **the accelerator's cost does not grow.** Scalar cost is linear in
the feature count; the accelerator's is flat. At 64 features it is ~15× fewer
instructions, and at `LANE_8` the dot product itself runs 8× faster on top of
that.

So: a 4-feature linear regression is not the workload that justifies this
hardware. It is the workload that *proves the hardware works* — and it shows the
shape of the win rather than the magnitude. The magnitude arrives with width.

> **Part 4 delivers it.** Scaling this workload to 64 and then 784 features
> exposed two real RTL bugs — the packed lanes were unreachable from the dot
> product path, and the operand buffer was a hard ceiling on model size rather
> than a tiling granularity. See
> [ML_BLOCKS_EXPLAINED_4.md](ML_BLOCKS_EXPLAINED_4.md). At 784 features the
> speedup is **65x**.

### Result

```
[775 ns]  sample 0: w.x = 18   ->  y = 28
[1115 ns] sample 1: w.x = 16   ->  y = 26
[1455 ns] sample 2: w.x = 3    ->  y = 13
[1795 ns] sample 3: w.x = 5    ->  y = 15

DMA fetches   = 4   (one per sample)
Dot products  = 4   (one per prediction)
out_port      = 82
Faults        = none
```

---

## 11. What is still not done

**Only inference, not training.** Gradient descent needs division and multiple
passes. The hardware has division (RV64M), so this is a software problem, not a
hardware gap.

**The next workloads up the ladder** ([ML_POST_ROADMAP.md](ML_POST_ROADMAP.md)):
logistic regression adds an activation function; a small MLP adds hidden layers
and is mostly matrix-vector multiply — which `matrix_tile` already does.

The remaining hardware gaps are unchanged from section 9: a 64-entry buffer, no
DMA write-back path, and a CPU that is not privileged-spec compliant.
