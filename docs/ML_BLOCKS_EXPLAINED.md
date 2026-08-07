# ML Blocks Explained

A ground-up walkthrough of the ML accelerator blocks added so far. Assumes no
prior familiarity with this code.

Covers only the new ML hardware:

- `src/mac_unit.v`
- `src/dot_product.v`
- `tb/tb_ml_ref.v`, `tb/tb_mac.v`, `tb/tb_dot_product.v`

The base CPU (ALU, register file, control unit, memories) is not discussed here.

---

## 1. Why these blocks exist at all

Nearly every machine-learning computation, when you strip away the framing,
reduces to the same inner loop: **multiply a pile of numbers pairwise, then add
up all the products.**

That operation is the *dot product*:

```
y = a[0]*b[0] + a[1]*b[1] + a[2]*b[2] + ... + a[n-1]*b[n-1]
```

A neural network layer is a stack of dot products. A convolution is a sliding
dot product. Matrix multiply is a grid of dot products. If you make the dot
product fast, you make ML fast. That is the entire premise.

The smallest repeated step inside that formula is:

```
running_total = running_total + (a * b)
```

Multiply two numbers, add the result to what you have so far. This is called a
**MAC** — Multiply-ACcumulate. It's the atom. The dot product is just a MAC
repeated in a loop.

So the build order is: **build the atom (MAC), then build the loop around it
(dot product).** That's what these two files are.

---

## 2. The building block: `mac_unit.v`

### What it computes

One thing, on every clock tick:

```
acc  <-  acc + (a * b)
```

`acc` (short for *accumulator*) is a register — a piece of memory inside the
hardware that holds a value and remembers it from one clock cycle to the next.
`a` and `b` are the two numbers coming in.

### Its ports

| Port | Direction | Meaning |
|---|---|---|
| `clk` | in | The clock. Everything happens on its rising edge. |
| `rst_n` | in | Reset. When held low, `acc` is forced to 0. |
| `a`, `b` | in | The two numbers to multiply (64 bits each by default). |
| `en` | in | "Enable." Only accumulate when this is 1. |
| `clear` | in | Zero the accumulator on the next clock edge. |
| `is_signed` | in | 1 = treat inputs as signed (can be negative), 0 = unsigned. |
| `acc` | out | The running total. |

### How to actually use it

To compute `3*4 + 5*6`:

```
cycle 0:  clear=1                    -> acc becomes 0
cycle 1:  a=3, b=4, en=1             -> acc becomes 0  + 12 = 12
cycle 2:  a=5, b=6, en=1             -> acc becomes 12 + 30 = 42
          acc now reads 42
```

Note `clear` and `en` are **separate signals**. That's deliberate. You need to
zero the accumulator before starting a fresh calculation, but you also need to
be able to *pause* (hold the total without adding to it) — those are different
actions, so they get different wires. If `en` is 0, `acc` just sits there
unchanged.

### The one subtle thing: the accumulator is wider than the inputs

This is the most important design rule in the whole ML doc set, and it's easy to
get wrong.

When you multiply two 64-bit numbers, the answer can need **128 bits**. Example:
`2^40 * 2^40 = 2^80`, which does not fit in 64 bits. If the accumulator were
only 64 bits wide, that result would be silently chopped and you'd get a wrong
answer with no warning.

Worse, you're *summing many products*. Even if each individual product fits, the
running total can outgrow it.

So: operands are 64-bit, the accumulator is **128-bit**. In the code:

```verilog
parameter OP_WIDTH  = 64,   // operand width
parameter ACC_WIDTH = 128   // accumulator width
```

The product is computed at full width and then sign-extended up to the
accumulator width *before* the addition, so nothing is lost at any step. That's
these lines:

```verilog
wire signed [PROD_WIDTH-1:0] prod_s = $signed(a) * $signed(b);
wire [ACC_WIDTH-1:0] addend =
    is_signed ? {{(ACC_WIDTH-PROD_WIDTH){prod_s[PROD_WIDTH-1]}}, prod_s}
              : {{(ACC_WIDTH-PROD_WIDTH){1'b0}},                 prod_u};
```

"Sign-extend" means: to widen a negative number, copy its top bit (the sign bit)
into all the new upper bits. That keeps `-12` reading as `-12` at 128 bits
instead of turning into a huge positive number.

### Signed vs unsigned

The same 64 bits mean different things depending on interpretation. All-ones
(`0xFFFF...FF`) is either `-1` (signed) or `18446744073709551615` (unsigned).
The `is_signed` input picks which. The hardware computes both products and
selects between them; a synthesis tool will discard the unused half if you tie
the signal to a constant.

---

## 3. The loop: `dot_product.v`

`mac_unit` handles *one* multiply-accumulate. A real dot product needs `n` of
them, fed the right operands in the right order. That sequencing is what
`dot_product.v` does.

**It does not reimplement multiplication.** It *contains* a `mac_unit` and
drives its control signals. That reuse is the point of the build order.

### The state machine

Hardware can't "run a for loop" — there's no program counter here. Instead you
build a **finite state machine (FSM)**: a register holding "which step am I on,"
plus rules for what to do in each step and when to move on.

This one has three states:

```
        start=1
IDLE ------------> RUN ------------> DONE ------> (back to IDLE)
 |                  |  ^               |
 |                  |__|               |
 |             (loop until             |
 |              last element)          |
 |                                     |
 +-- if vec_len==0, skip straight to DONE
```

- **IDLE** — sitting there waiting. When `start` goes high, it captures the
  vector length and the signed/unsigned mode, zeroes the accumulator, and moves
  to RUN.
- **RUN** — one element per clock cycle. Emits an index `idx`, the operands for
  that index arrive, the MAC accumulates them, `idx` increments. Repeats until
  the last element.
- **DONE** — the final MAC has landed, so the answer is valid. Pulses `done` for
  one cycle and returns to IDLE.

### How it gets its numbers: the streaming interface

The unit does **not** hold the vectors internally. It asks for them one at a
time:

```
dot_product  ---- idx (which element do I want?) ---->  [operand source]
             <--- a_data, b_data (here it is)  -------
```

It outputs an index, and whoever is connected must present `a[idx]` and `b[idx]`
on the data wires that same cycle.

This is deliberate. The operands might eventually live in main memory, in a fast
local scratchpad, in CPU registers, or in accelerator-mapped registers — and
that decision hasn't been made yet ([ML_INTERFACE.md](ML_INTERFACE.md) proposes
memory-mapped, but it's not built). By streaming an index, this block works with
*any* of those without modification. In the testbench, the "operand source" is
just a Verilog array.

### The handshake

How software (or another block) talks to it:

1. Put the vector length on `vec_len` and the mode on `is_signed`.
2. Pulse `start` high for one cycle.
3. The unit raises `busy` and grinds through the elements.
4. When it finishes, it pulses `done` for one cycle; `result` now holds the
   answer.

`vec_len = 0` is handled: it completes immediately with a result of 0, rather
than hanging or looping forever.

### The bug that lived here (and why it's worth knowing)

The first version of this FSM was wrong, and it's an instructive kind of wrong.

`idx` is a **registered** output — it updates on the clock edge. The operands
`a_data`/`b_data` are driven **combinationally** from `idx` — they change
immediately when `idx` changes, no clock involved.

I originally made `mac_en` (the MAC's enable) registered too. That meant the
enable arrived **one cycle later** than the data it was supposed to be gating.
The consequence, traced live:

```
accumulator over time:  0 -> 0 -> 10 -> 28 -> 46      (expected 32)
```

For `[1,2,3]·[4,5,6]`: element 0 (`1*4`) was **never accumulated** because the
enable hadn't gone high yet, and element 2 (`3*6`) got counted **twice** because
the enable was still high after `idx` stopped advancing. `10 + 18 + 18 = 46`.

The fix: make `mac_en` and `mac_clear` **combinational functions of the state**,
so the enable is high during exactly the cycle its operands are on the bus:

```verilog
wire mac_en    = (state == S_RUN);
wire mac_clear = (state == S_IDLE) && start;
```

Now the accumulator walks `0 -> 4 -> 14 -> 32`. Correct.

**The lesson:** in streaming hardware, a control signal and the data it controls
must be *phase-aligned*. Register one but not the other and you get an off-by-one
that is invisible in the source and only shows up in a waveform.

The tell was that **length-1 vectors passed** while everything longer failed — at
length 1, dropping the first element and double-counting the last one cancel out
exactly. A test suite that only checked single-element vectors would have shipped
this bug.

---

## 4. How the two connect

```
                    ┌─────────────────────────────────────┐
   start ──────────►│           dot_product               │
   vec_len ────────►│                                     │
   is_signed ──────►│   ┌──────────────────────────┐      │
                    │   │  FSM: IDLE / RUN / DONE  │      │
                    │   └────────────┬─────────────┘      │
                    │                │                    │
                    │      mac_clear │ mac_en   sign_q    │
                    │                ▼                    │
   idx ◄────────────┼───┐   ┌─────────────────────┐       │
                    │   │   │      mac_unit       │       │
   a_data ──────────┼───┼──►│  acc <= acc + a*b   │       │
   b_data ──────────┼───┼──►│                     │       │
                    │   │   └──────────┬──────────┘       │
                    │   │              │ acc              │
                    │   └──────────────┼────────►         │
   busy  ◄──────────┤                  │                  │
   done  ◄──────────┤                  │                  │
   result ◄─────────┼──────────────────┘                  │
                    └─────────────────────────────────────┘
```

The FSM owns the sequencing; the MAC owns the arithmetic. `result` is wired
straight out of the MAC's accumulator — the dot product unit never touches the
number itself.

**Timing for a 3-element dot product** (this is the whole thing, cycle by cycle):

| Cycle | State | `idx` | operands on bus | `mac_en` | `acc` after edge |
|---|---|---|---|---|---|
| 0 | IDLE | – | – | 0 | – |
| 1 | IDLE→RUN | 0 | `a[0]`,`b[0]` | 0 (clear=1) | 0 |
| 2 | RUN | 0 | `a[0]`,`b[0]` | 1 | `1*4` = 4 |
| 3 | RUN | 1 | `a[1]`,`b[1]` | 1 | `4 + 2*5` = 14 |
| 4 | RUN | 2 | `a[2]`,`b[2]` | 1 | `14 + 3*6` = 32 |
| 5 | DONE | 2 | – | 0 | 32, `done` pulses |

Throughput is **one element per cycle**. A 3-element dot product takes ~5 cycles
end to end.

---

## 5. The testbenches

A **testbench** is not hardware. It's a simulation-only program that wiggles the
inputs of a design, watches the outputs, and shouts if they're wrong. It never
gets built into a chip.

The strategy across all three files is the same, and it's the reason the RTL bug
above got caught:

> Write the answer **twice** — once in plain software (obviously correct, slow,
> not synthesizable), once in hardware (fast, but easy to get subtly wrong).
> Then check they agree.

The software version is called a **golden model** or **reference model**.

### `tb_ml_ref.v` — golden models only, no hardware (5 checks)

Written *before* any RTL existed. It implements MAC and dot product as plain
Verilog functions and verifies them against hand-computed values from
[ML_TEST_PLAN.md](ML_TEST_PLAN.md), e.g. `[1,2,3]·[4,5,6] = 32`.

This seems pointless — of course software addition works — but it's step 1 of
the implementation order for a reason: it pins down *exactly* what "correct"
means (widths, signedness, overflow behavior) before there's any hardware to
argue with. Later testbenches check the hardware against this definition.

### `tb_mac.v` — the MAC block vs. the golden model (31 checks)

Instantiates `mac_unit`, drives it, and compares every result against the
software model. Beyond the basic vectors it deliberately probes the places
hardware breaks:

- reset zeroes the accumulator
- `clear` zeroes it
- `en=0` **holds** the value (garbage on `a`/`b` must be ignored)
- signed vs. unsigned give different answers for the *same input bits*
- `2^40 * 2^40 = 2^80` survives — proves the product isn't truncated
- accumulating a negative product across zero (`100 - 180 = -80`)
- **running `[1,2,3]·[4,5,6]` as three back-to-back MACs** — proving the atom
  composes into the loop before the loop is even built

### `tb_dot_product.v` — the dot product vs. the golden model (13 checks)

Models the operand source as two Verilog arrays indexed by the DUT's `idx`,
runs full dot products, and checks each against a software loop.

Edge cases, straight from the test plan:

- empty vector (`len=0`) — must finish, not hang
- `len=1` — degenerates to a single MAC
- odd length
- negative values, and negative×negative
- widened accumulator (four `2^80` products summing to `2^82`)
- unsigned mode
- 32-element vector
- **back-to-back runs** — the second must clear the accumulator, not inherit the
  first one's total

It also has a **timeout guard**: if `done` never arrives within 1000 cycles, it
reports a failure instead of hanging the simulator forever. Hardware bugs cause
hangs, and a hang with no message is a miserable thing to debug.

---

## 6. Running them

```sh
# software golden models
iverilog -I src -o ml_ref.vvp tb/tb_ml_ref.v && vvp ml_ref.vvp

# MAC block
iverilog -I src -o mac.vvp src/mac_unit.v tb/tb_mac.v && vvp mac.vvp

# dot product (needs mac_unit too - it instantiates it)
iverilog -I src -o dot.vvp src/mac_unit.v src/dot_product.v tb/tb_dot_product.v \
  && vvp dot.vvp
```

Each prints a per-check `ok` / `FAIL` line and a summary. Current status: **49
checks, 0 errors.**

Note `run.bat` builds the *base CPU* only and does not pick these up.

---

## 7. Where this sits in the roadmap

From [ML_RTL_IMPLEMENTATION_ORDER.md](ML_RTL_IMPLEMENTATION_ORDER.md):

| Step | Status |
|---|---|
| 1. Testbench reference models and self-checkers | done — `tb_ml_ref.v` |
| 2. Standalone MAC RTL block | done — `mac_unit.v` |
| 3. Dot-product control around MAC | done — `dot_product.v` |
| 4. Packed vector lane support (int8/int16) | next |
| 5. Horizontal reduction path | not started |
| 6. Matrix-tile controller | not started |

**These blocks are not yet connected to the CPU.** They are standalone and
verified in isolation. Wiring them in (via the memory-mapped registers proposed
in [ML_INTERFACE.md](ML_INTERFACE.md)) is a separate job.

### Why step 4 matters

Right now the dot product does **one 64-bit MAC per cycle**. But ML rarely needs
64-bit precision — 8-bit weights are routinely enough.

If you pack **eight int8 values** into each 64-bit operand and multiply them
lane-by-lane, you get **8 MACs per cycle** out of the same wires and the same
register width. That's an 8× throughput increase for free. That is where the
actual ML speedup comes from, and it's why the roadmap puts lanes right after
the scalar dot product works.
