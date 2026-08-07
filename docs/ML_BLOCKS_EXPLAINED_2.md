# ML Blocks Explained, Part 2

Continues [ML_BLOCKS_EXPLAINED.md](ML_BLOCKS_EXPLAINED.md), which covered the
scalar `mac_unit` and `dot_product`. Same assumption: no prior familiarity with
this code.

This part covers the pieces that make the accelerator **fast** and make it
**reachable from software**:

- `src/vec_mac.v` — packed lanes: 8 multiply-accumulates per cycle
- `src/ml_accel.v` — the memory-mapped interface the CPU talks to
- `src/cpu_top.v` — how it hooks into the CPU (a small, contained change)
- `program_ml.asm` — a real program that uses it
- `tb/tb_vec_mac.v`, `tb/tb_ml_accel.v`, `tb/tb_cpu_ml.v` — how it's verified

---

## 1. The problem with what we had

Part 1 ended with a working dot product. It processes **one element per cycle**.

That's correct, but it's not an accelerator — it's just a MAC with a loop
counter. A 64-element dot product takes 64 cycles. The CPU could nearly do that
itself. We haven't actually made anything faster.

The insight that fixes this: **ML almost never needs 64-bit precision.**

Neural network weights are routinely stored as 8-bit integers. So when you feed
a 64-bit-wide multiplier an 8-bit weight, **56 of those 64 bits are wasted** —
they're just sign-extension padding. You're paying for a 64-bit datapath and
using an eighth of it.

So: stop wasting them. Cram **eight independent 8-bit values** into each 64-bit
operand and multiply all eight pairs *simultaneously*. Same wires, same register
width, same one cycle — **eight times the work.**

That's `vec_mac.v`.

---

## 2. `vec_mac.v` — packed lanes

### What "packed" means

A 64-bit register is just 64 bits. Nothing forces you to read it as one number.
You can *choose* to read it as eight separate 8-bit numbers laid end to end:

```
      one int64:  [                    42                          ]
                   63                                              0

  eight int8s:  [ 8 | 7 | 6 | 5 | 4 | 3 | 2 | 1 ]
                  63                             0
                lane7                          lane0
```

Same 64 bits. Different interpretation. Each 8-bit slot is called a **lane**.

Note the ordering: **lane 0 is the LOW byte.** So the vector `[1,2,3,4,5,6,7,8]`
packs into the hex literal `0x0807060504030201` — it reads *backwards* from what
you might expect. This trips people up constantly; it's why the testbench
comments call it out explicitly.

### What the block computes

Every enabled cycle, in parallel across all lanes:

```
acc  <-  acc  +  ( a[0]*b[0] + a[1]*b[1] + ... + a[7]*b[7] )
                  \_________________________________________/
                        all eight products, summed
```

Two things happen at once:

1. **Lane-parallel multiply** — all 8 lane-pairs multiply simultaneously.
2. **Horizontal reduction** — the 8 products are summed down to a single number.

"Horizontal" means *across* the lanes (collapsing them into one value), as
opposed to the normal "vertical" lane-wise operations that keep lanes separate.
The reduction is what turns 8 parallel products back into one dot-product
contribution. In the roadmap these were steps 4 and 5; they're folded into one
block because a lane-parallel multiply is useless without a way to sum the lanes.

### Lane modes

The width is selectable at runtime via the `lane_mode` input:

| `lane_mode` | Interpretation | MACs per cycle |
|---|---|---|
| `LANE_8` (0) | 8 × int8 | **8** |
| `LANE_16` (1) | 4 × int16 | 4 |
| `LANE_32` (2) | 2 × int32 | 2 |
| `LANE_64` (3) | 1 × int64 | 1 — same as `mac_unit` |

Lower precision, more parallelism. `LANE_64` is the escape hatch: it behaves
exactly like the scalar `mac_unit` from part 1, which is what lets the testbench
compare the two directly.

### The precision rule, applied per-lane

Part 1's central rule was *the accumulator must be wider than the operands*.
Here it applies **to every lane**, and the trap is subtler.

An `int8 × int8` product needs **16 bits** (e.g. `-128 × -128 = +16384`, which
does not fit in 8 bits). And then you're *summing eight of those*, so the total
needs even more headroom.

The code therefore computes each lane product at its natural double width, then
**widens it to the full 128-bit accumulator width before adding it into the
sum**:

```verilog
p8 = $signed(a8) * $signed(b8);                    // 16-bit product
sum8 = sum8 + {{(ACC_WIDTH-16){p8[15]}}, p8};      // widen, THEN add
```

If you summed the 16-bit products *first* and widened afterwards, eight of them
could overflow 16 bits and you'd lose the top bits silently. Widen first, add
second. The `-128 × -128` across 8 lanes test (expecting exactly 131072) exists
to catch precisely this.

### The test that justifies the whole block

`tb_vec_mac.v` computes the **same 64-element int8 dot product two ways**:

- **Scalar**: 64 cycles, one element at a time (`LANE_64`) → **159**
- **Packed**: 8 cycles, eight at a time (`LANE_8`) → **159**

Identical answer. **8× fewer cycles.** The vectors deliberately mix positive and
negative values so that a sign-handling bug in any lane couldn't accidentally
produce the right total.

That single check is the entire justification for the accelerator existing.

---

## 3. `ml_accel.v` — making it reachable from software

At this point we have fast hardware that **no program can use.** `vec_mac` is a
box with wires. The CPU has no idea it exists. There is no instruction that says
"do a vector MAC."

There are two ways to fix that:

1. **Add custom instructions** to the ISA — invasive. You must modify the
   decoder, the control unit, the assembler, and you've now forked RISC-V.
2. **Memory-mapped I/O (MMIO)** — the accelerator pretends to be *memory*.
   Software talks to it with the `SD` (store) and `LD` (load) instructions it
   already has.

[ML_INTERFACE.md](ML_INTERFACE.md) recommends #2 for bring-up, and that's what's
built. **Zero ISA changes. Zero new instructions.**

### How MMIO works

Certain memory addresses aren't really memory. When the CPU stores to address
`0xD0`, that value doesn't land in RAM — it lands in the accelerator's operand
register. The address decoder intercepts it.

Your CPU already did this: `out_port`, the debug output, was wired to a reserved
address. The accelerator uses the same trick, just with more registers.

### The register map

> **Superseded.** These addresses are from before the memory was widened to 2 KB.
> The accelerator now lives at `0x780`, with three extra DMA registers. See
> [part 3](ML_BLOCKS_EXPLAINED_3.md) for the current 16-slot map. The layout
> below is kept because the surrounding explanation refers to it.

| Address | Name | R/W | Purpose |
|---|---|---|---|
| `0xC0` | `ML_CTRL` | W | start / clear / signed / lane_mode |
| `0xC8` | `ML_STATUS` | R | status bits |
| `0xD0` | `ML_A` | W | packed operand A |
| `0xD8` | `ML_B` | W | packed operand B |
| `0xE0` | `ML_ACC_LO` | R | accumulator, low 64 bits |
| `0xE8` | `ML_ACC_HI` | R | accumulator, high 64 bits |
| `0xF8` | `out_port` | W | pre-existing debug port (**moved from `0xFF`** — see below) |

### Why the registers are 8 bytes apart

This spacing is a **RISC-V requirement, not a style choice.**

The spec permits `SD` and `LD` only at **doubleword-aligned** addresses — the low
three address bits must be zero. Software delivers the 64-bit packed operands
with `SD`, so every accelerator register must sit at an address ending in `0` or
`8`.

An earlier version of this block put the registers one byte apart (`0xF0`, `0xF1`,
`0xF2`, …). That is **not compliant**: `SD` to `0xF2` is a misaligned store, and a
conformant core must trap it. It appeared to work here only because suppressing
`data_memory` for accelerator addresses also disabled the misalignment detector
that lives inside it — the check was silently bypassed. Spacing the registers 8
bytes apart removes the problem at the source rather than papering over it.

### The same bug was in the base CPU

Chasing this down exposed the root cause, which was **not** in the accelerator:

`data_memory` was the *only* thing computing `misaligned_access`. Any address
that bypasses `data_memory` therefore skipped alignment checking entirely. That
was already true of MMIO before the accelerator existed.

And it had a concrete consequence: **`out_port` used to live at `0xFF`**, whose
low three bits are `111`. An `SD` to `0xFF` is misaligned, so a conformant RV64
core must trap it — meaning the debug port was **unreachable by any legal store**.
It only worked because the check was being skipped.

Two fixes, both in `cpu_top.v`:

1. **Alignment is now checked in `cpu_top`**, derived from the address and
   `funct3` alone, so it holds for *every* destination — RAM, MMIO, and the
   accelerator alike, regardless of which one is enabled.
2. **`out_port` moved from `0xFF` to `0xF8`**, the last doubleword-aligned slot,
   so it is reachable by a compliant `SD`.

A misaligned `SD` now correctly raises `mem_fault` and traps, which was verified
with a deliberately misaligned test program.

The accumulator is 128 bits but the CPU's registers are only 64, so it's exposed
as **two registers**. Read `ML_ACC_LO` for normal results; read `ML_ACC_HI` only
when the total exceeds 64 bits.

`ML_CTRL` bit layout:

```
  bit  [0]    start      pulse - accumulate A*B now
  bit  [1]    clear      pulse - zero the accumulator
  bit  [2]    is_signed  level - 1 = signed lanes
  bits [4:3]  lane_mode  level - 0=int8, 1=int16, 2=int32, 3=int64
```

So the control word `0x05` = `start | signed`, with `lane_mode = 0` (int8).
And `0x02` = `clear`.

### Pulses vs. levels — a real design subtlety

`start` and `clear` are **pulses**, not levels. They are high only for the single
cycle the CPU's store lands:

```verilog
wire ctrl_write  = sel && we && (reg_idx == ML_CTRL);
wire start_pulse = ctrl_write && wdata[0];
```

Why this matters: if `start` were a *level* — high for as long as the bit is set
— the accumulator would keep accumulating the same operands **every cycle** until
software cleared the bit. One store would produce an unpredictable number of
MACs depending on how fast software got around to writing the register again.

By making it a pulse tied to the write itself, **one store = exactly one
accumulate.** Deterministic. It's what lets the program below just fire stores
back to back.

### The software recipe

```
1.  store ML_CTRL  <- 0x02              # clear the accumulator
2.  for each 8-element chunk:
      store ML_A    <- packed a[i..i+7]
      store ML_B    <- packed b[i..i+7]
      store ML_CTRL <- 0x05             # start: 8 MACs in ONE cycle
3.  load  ML_ACC_LO                     # read the result
```

Three stores per chunk of eight elements. That's the whole API.

---

## 4. Hooking into the CPU (`cpu_top.v`)

This is the only change to base CPU RTL, and it's deliberately small — the
roadmap's rule is *keep the base CPU stable while adding ML blocks*. Four edits:

**1. Address decode.** Recognize the accelerator's address range:

```verilog
assign is_ml_addr =
    (alu_result[DATA_ADDR_WIDTH-1:6] == ML_BASE[DATA_ADDR_WIDTH-1:6]) &&
    !is_mmio_addr;
```

The `!is_mmio_addr` term keeps `out_port` (0xF8) out of the block, so existing
behavior is untouched.

**2. Instantiate the accelerator**, fed by the store data (`reg_read2`) and the
low address bits as a register index.

**3. Suppress RAM** for accelerator addresses — otherwise a store to `0xD0` would
*also* write real memory:

```verilog
.mem_read  (mem_read_safe  && !is_mmio_addr && !is_ml_addr),
.mem_write (mem_write_safe && !is_mmio_addr && !is_ml_addr),
```

**4. Route loads back.** A load from `0xE0` must return the accelerator's
register, not RAM:

```verilog
wire [XLEN-1:0] load_data = is_ml_addr ? ml_rdata : mem_read_data;
```

### Proving it changed nothing else

Modifying the CPU risks breaking it. So the integration was verified by running
the existing CPU testbench **with and without** the accelerator wired in and
diffing the output:

> **byte-for-byte identical.**

The accelerator is genuinely additive. Nothing that worked before behaves any
differently.

### The memory budget

> **Superseded:** RAM was later widened to **2 KB** and the accelerator moved to
> `0x780`. See [part 3](ML_BLOCKS_EXPLAINED_3.md) section 8. The paragraph below
> describes the original layout.

Worth knowing: data RAM is only **256 bytes** (`DATA_ADDR_WIDTH = 8`). The
accelerator claims the top 64 bytes (`0xC0`–`0xFF`, with `out_port` at `0xF8`),
so usable RAM is everything below `0xC0` — **192 bytes.** Current programs use a handful, so
there's plenty of room, but it is not unlimited.

---

## 5. `program_ml.asm` — the end-to-end proof

Everything above could be individually correct and still not work together. This
program is the real test: a genuine RISC-V program, on the real CPU, using only
instructions the ISA already had.

It computes a **16-element int8 dot product**:

```
a = b = [1,2,3,4,5,6,7,8, 1,2,3,4,5,6,7,8]

dot = 2 * (1 + 4 + 9 + 16 + 25 + 36 + 49 + 64)
    = 2 * 204
    = 408
```

### Building a packed operand in assembly

There's a wrinkle. The program needs the 64-bit constant `0x0807060504030201` in
a register — but `ADDI` only carries a **12-bit immediate**. You cannot load a
64-bit constant in one instruction.

So it's built one byte at a time, shifting left and OR-ing in the next byte:

```asm
ADDI x1, x0, 8       # x1 = 0x08
SLLI x1, x1, 8       # x1 = 0x0800
ADDI x1, x1, 7       # x1 = 0x0807
SLLI x1, x1, 8       # x1 = 0x080700
ADDI x1, x1, 6       # x1 = 0x080706
...                  # and so on down to byte 1
```

Sixteen instructions to construct one constant. In a real system the vectors
would be loaded from memory rather than synthesized — but this keeps the demo
self-contained.

### The trace

Running `tb_cpu_ml.v`, the accelerator traffic is visible cycle by cycle:

```
ML store: reg[0] <= 0x02                  <- clear
ML store: reg[2] <= 0x0807060504030201    <- ML_A = [1..8]
ML store: reg[3] <= 0x0807060504030201    <- ML_B = [1..8]
ML store: reg[0] <= 0x05                  <- start: 8 MACs in ONE cycle
ML store: reg[2] <= 0x0807060504030201    <- chunk 2
ML store: reg[3] <= 0x0807060504030201
ML store: reg[0] <= 0x05                  <- start: 8 more MACs
ML load:  reg[4] => 408                   <- read result
out_port = 408
```

Sixteen elements, **two accumulate steps**, zero faults. That's the packing
working in a real program, not just a testbench.

---

## 6. Three bugs found in the base CPU test

Wiring the accelerator in meant running the CPU testbench — which turned out to
have **never passed**. Three independent bugs, all pre-existing:

**1. `program.asm` did not assemble.** It used `STORE` and `LOAD`, which are
*opcode names* in the assembler, not instruction mnemonics — the real ones are
`SD` and `LD`. Running `tools/assembler.py` on it threw an exception. The
committed `program.mem` had been produced some other way and had **silently
drifted from its own source**: it encoded 32-bit `SW`/`LW` while the source
implied a full 64-bit store. The `.asm` file was decorative.

**2. The program never halted.** After its last instruction the PC kept
incrementing into **zeroed ROM**, and all-zeros decodes as an illegal
instruction. That raised `illegal_instr` and `core_fault` and looked exactly like
a broken CPU — but it was just a program running off its own end. Bare-metal
programs need an explicit halt; the convention is a self-loop:

```asm
halt:
JAL x0, halt        # jump to myself, forever
```

**3. The testbench could not report PASS.** Every terminating path hardcoded
`test_pass <= 1'b0` — *including* the stuck-PC path, which is exactly what a
deliberate halt looks like. And it never checked the program's actual result. It
now compares `out_port` against the expected value.

The lesson worth carrying: **a test that cannot pass is not a test.** It had been
sitting there reporting `FAIL` and everyone had learned to read past it.

---

## 7. Running everything

```sh
# ML blocks
iverilog -I src -o vec.vvp   src/vec_mac.v tb/tb_vec_mac.v          && vvp vec.vvp
iverilog -I src -o acc.vvp   src/vec_mac.v src/ml_accel.v tb/tb_ml_accel.v && vvp acc.vvp

# CPU (base program)
iverilog -I src -o cpu.vvp   src/*.v tb/tb_cpu.v                    && vvp cpu.vvp

# CPU + accelerator, end to end
python tools/assembler.py program_ml.asm program_ml.mem
iverilog -I src -o cpuml.vvp src/*.v tb/tb_cpu_ml.v                 && vvp cpuml.vvp
```

Current status: **79 checks across 5 ML testbenches, plus both CPU tests
passing, 0 errors.**

The `$readmemh ... Not enough words` warnings are harmless — the ROM holds 256
words and the programs are far shorter, so the remainder is zero-filled. Both
programs halt long before reaching it.

---

## 8. Where the roadmap stands

| Step | Status |
|---|---|
| 1. Testbench reference models | done — `tb_ml_ref.v` |
| 2. Standalone MAC RTL | done — `mac_unit.v` |
| 3. Dot-product control | done — `dot_product.v` |
| 4. Packed vector lanes | done — `vec_mac.v` |
| 5. Horizontal reduction | done — folded into `vec_mac.v` |
| 6. Matrix-tile controller | done — `matrix_tile.v` (**part 3**) |
| — CPU integration | done — `ml_accel.v` + `cpu_top.v` |

The accelerator is a working part of the CPU, driven by real software.

> **Note (superseded):** the sections below described the state of the code when
> this part was written. Both limitations have since been fixed — see
> [ML_BLOCKS_EXPLAINED_3.md](ML_BLOCKS_EXPLAINED_3.md), which adds the matrix
> tile controller and rewrites `ml_accel.v` so **all three engines are reachable
> from software**. The register map in this document is also out of date; part 3
> has the current one.

### The limitation at the time of writing (now fixed)

`dot_product.v` (part 1) and `ml_accel.v` were **separate paths**. The
memory-mapped interface drove `vec_mac` directly, with software supplying one
packed chunk per store. The `dot_product` FSM — which streams a whole vector
autonomously — was verified but **not wired to the CPU**, so software had to run
the chunk loop itself.

Part 3 fixes this by giving the accelerator its own operand buffer: software
fills it, writes `start` once, and the engine runs the whole vector — or the
whole matrix multiply — by itself.
