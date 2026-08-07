# RISC-V Compliance Status

An honest accounting of what this core does and does not implement, and what has
actually been verified against the specification.

**Last audited:** 2026-07-12, at commit `6e97886`.

---

## The one-line answer

> **An RV64IM core with a partial Zbb subset, verified against the spec for
> instruction semantics. Not privileged-spec conformant: no CSRs, no traps, no
> `ECALL`.**

That statement is defensible. **"RISC-V compliant"** without qualification is
**not** — formal compliance means passing
[riscv-arch-test](https://github.com/riscv-non-isa/riscv-arch-test), the official
conformance suite, which exercises the privileged spec and would fail
immediately on the missing CSRs.

The distinction matters. "Every test passes" and "this is a conformant RISC-V
implementation" are different claims, and only the first one is true here.

---

## What IS implemented and verified

The instruction semantics that exist are correct. This is not an assertion — it
is backed by ~9,800 checks against models written from the spec, deliberately
independent of this RTL and of the project's own assembler.

| Area | Status | Evidence |
|---|---|---|
| **RV64I** base integer | ✅ verified | 8,092 ALU vectors |
| **RV64M** mul/div (all 8 ops) | ✅ verified | incl. div-by-zero and `INT_MIN/-1` overflow |
| **RV64 `*W`** word ops | ✅ verified | 32-bit ops, sign-extended results |
| Immediates (I/S/B/U/J) | ✅ verified | 400 vectors, sign-extension boundaries |
| Branch comparisons | ✅ verified | 1,200 vectors straddling the sign boundary |
| Load/store extension | ✅ verified | `LB`/`LH`/`LW` sign vs `LBU`/`LHU`/`LWU` zero |
| Address alignment | ✅ verified | enforced for RAM, MMIO, and accelerator alike |
| `x0` hardwired to zero | ✅ verified | writes discarded in `register_file.v` |
| `JALR` clears target LSB | ✅ verified | per spec |
| Shift-amount masking | ✅ verified | 6 bits for RV64, 5 bits for `*W` |

**Decoded opcodes (11):** `OP`, `OP-IMM`, `OP-32`, `OP-IMM-32`, `LOAD`, `STORE`,
`BRANCH`, `JAL`, `JALR`, `LUI`, `AUIPC`.

See [ML_BLOCKS_EXPLAINED_2.md](ML_BLOCKS_EXPLAINED_2.md) for the ML accelerator,
which adds **zero ISA surface** — no custom opcodes, decoder untouched, driven
entirely by standard `SD`/`LD`.

---

## What is NOT compliant

### 1. No CSRs, no `ECALL` / `EBREAK` / `FENCE`

The **SYSTEM** opcode (`1110011`) is not decoded anywhere in the core. Neither is
**MISC-MEM** (`0001111`, `FENCE`). Verified by grep — they simply are not there.

This means:

- **No Zicsr extension.** CSR access (`CSRRW`, `CSRRS`, `CSRRC`, …) is the
  mechanism by which RISC-V software reads and writes machine state. Without it
  there are no control/status registers at all.
- **No `ECALL`.** This is the system-call instruction. It is part of **base
  RV64I**, not an optional extension — so the core is not even a complete RV64I
  implementation on this point.
- **No `EBREAK`.** No debugger breakpoint support.

**Consequence:** the core cannot run an operating system, a language runtime, or
any program that makes a system call. It runs bare-metal programs that never ask
the machine for anything.

### 2. Faults do not trap — this is the significant one

The core detects faults (`illegal_instr`, `fetch_fault`, `mem_fault`) and
aggregates them into `core_fault`. It then uses that flag to **suppress side
effects**: register writes, memory writes, and control transfers are gated off.

But look at what happens to the program counter ([cpu_top.v](../src/cpu_top.v)):

```verilog
assign next_pc_val =
    (jalr_safe)   ? jalr_target   :
    (jump_safe)   ? jal_target    :
    (take_branch) ? branch_target :
                    pc_plus_4;
```

`core_fault` **does not appear**. On a fault, the PC simply advances to
`pc_plus_4` and the core keeps executing. The faulting instruction is quietly
skipped.

A conformant RISC-V core must take an **exception**:

| Required | Present? |
|---|---|
| Save the faulting PC to `mepc` | ❌ no `mepc` |
| Record the cause in `mcause` | ❌ no `mcause` |
| Jump to the handler at `mtvec` | ❌ no `mtvec`, no handler |
| Enter a more privileged mode | ❌ no privilege modes |

**What this means in practice:** a misaligned store on real RISC-V hardware traps
to software, which can emulate it, kill the process, or report an error. Here it
is *silently discarded*. The instruction has no effect and execution continues as
if nothing happened.

This is worth being precise about, because the compliance audit *did* fix a real
bug here — misaligned accesses used to slip through the check entirely for MMIO
and accelerator addresses, which could corrupt state. That is now correctly
detected and suppressed. **Suppression is safe, but it is not what the spec
requires.** The spec requires a trap.

### 3. Partial Zbb (bit-manipulation) subset

The core implements **4 of roughly 17** Zbb instructions:

| Implemented | Missing |
|---|---|
| `ANDN`, `ORN`, `XNOR` | `CLZ`, `CTZ`, `CPOP` |
| `ROL`, `ROR` | `MAX`, `MAXU`, `MIN`, `MINU` |
| | `SEXT.B`, `SEXT.H`, `ZEXT.H` |
| | `RORI`, `ORC.B`, `REV8` |

These four are genuine Zbb encodings and they compute the right answers. But a
hand-picked subset **cannot claim Zbb conformance** — software that detects
"Zbb is available" and then issues `CLZ` would hit an undecoded instruction.

If you want the extension advertised honestly, either complete it or describe it
as "selected Zbb instructions," which is what
[defines.v](../src/defines.v) already calls it.

---

## Two bugs this audit found and fixed

Both were in **base CPU RTL**, predating the ML accelerator work. Both would
produce wrong answers on correct programs.

### `DIVW`/`REMW` computed *unsigned* division

```
DIVW(-1, 2)  returned 0x7FFFFFFF   (should be 0)
DIVW(1, -1)  returned 0            (should be -1)
```

`0x7FFFFFFF` is `(2³² − 1) / 2` — the operands were being divided as unsigned.

The `$signed` wires were correct. The bug was a **Verilog signedness trap**: in a
ternary, if *any* operand is unsigned, the *entire* expression is evaluated as
unsigned. The `32'hFFFFFFFF` divide-by-zero literal silently demoted the signed
division sitting in the other branch.

Fixed by computing the signed quotient into a signed reg *first*, then selecting
with `if/else`. The full-width `DIV`/`REM` were already safe — they use `if/else`
statements, so no unsigned literal enters the expression.

### Alignment was never checked for MMIO or accelerator addresses

`data_memory` was the **only** thing computing `misaligned_access`, and that logic
lives inside `if (mem_read) / else if (mem_write)`. Any address that bypasses
`data_memory` — MMIO, the accelerator — deasserted those inputs, so the flag read
`0` and the check was **vacuous for exactly the addresses that most needed it**.

This had a concrete consequence: `out_port` used to live at `0xFF`, whose low
three bits are `111`. RISC-V permits `SD` only at doubleword-aligned addresses, so
an `SD` to `0xFF` is misaligned — **the debug port was unreachable by any legal
store.** It only worked because the check was being skipped.

Fixed by computing alignment in `cpu_top` from the address and `funct3` alone, so
it holds for every destination, and moving `out_port` to an aligned address.

> **Note:** the data memory was later widened from 256 B to 2 KB to make room for
> the ML accelerator's DMA, so `out_port` now lives at `0x7F8` rather than `0xF8`.
> The alignment reasoning is unchanged — it is still the last doubleword-aligned
> slot in the address space. See
> [ML_BLOCKS_EXPLAINED_3.md](ML_BLOCKS_EXPLAINED_3.md) section 8.

---

## Verification methodology

Three principles, each learned the hard way during this audit:

**1. The reference model must be independent.** The vector generators
([tools/gen_alu_vectors.py](../tools/gen_alu_vectors.py),
[gen_imm_vectors.py](../tools/gen_imm_vectors.py),
[gen_branch_vectors.py](../tools/gen_branch_vectors.py)) implement the spec from
scratch. They do **not** import `assembler.py` and do **not** read the RTL.
Checking a tool against itself proves nothing.

**2. A test that silently drops input is worse than no test.**
`tb_alu_compliance` initially capped at 6,000 vectors while the generator produced
8,092. It reported **zero errors** — because the first 6,000 happened to be clean
and every failing vector was in the truncated tail. Raising the cap exposed all
170 failures at once. The testbenches now warn when they hit the cap.

**3. A test that cannot fail is not a test.** `tb_cpu_isa` was mutation-tested:
injecting the classic RV32-port bug (zero-extending the U-type immediate instead
of sign-extending) makes it fail immediately with the sentinel. This is the same
lesson as `tb_cpu`, which had hardcoded `test_pass <= 1'b0` on every exit path and
had *never* reported PASS — everyone had simply learned to read past the FAIL.

---

## Test suite

| Testbench | Checks | Covers |
|---|---|---|
| `tb_alu_compliance` | 8,092 | RV64I + RV64M + `*W`, vs spec model |
| `tb_branch_compliance` | 1,200 | signed vs unsigned comparison |
| `tb_imm_compliance` | 400 | all five immediate formats |
| `tb_ldst_compliance` | 19 | sign/zero extension, store width, alignment |
| `tb_cpu_isa` | program | LUI/branches/loads/`x0` on real hardware |
| `tb_cpu` | program | base smoke test |
| `tb_cpu_ml` | program | accelerator end-to-end |
| `tb_ml_ref`, `tb_mac`, `tb_dot_product`, `tb_vec_mac`, `tb_ml_accel` | 79 | ML accelerator blocks |

**Total: 9,790 checks across 12 testbenches, 0 errors.**

Regenerate vectors before running the compliance tests:

```sh
python tools/gen_imm_vectors.py    imm_vec.txt    400
python tools/gen_alu_vectors.py    alu_vec.txt   3000
python tools/gen_branch_vectors.py branch_vec.txt 1200
```

---

## Path to conformance

If the goal is a core that could actually boot something, the ordered path is:

**1. Traps.** The single highest-value addition. Add `mtvec`, `mepc`, `mcause`,
and make `core_fault` redirect `next_pc_val` to the handler instead of falling
through to `pc_plus_4`. This turns "faults are suppressed" into "faults are
handled," which is the actual spec requirement.

**2. Zicsr.** Decode the SYSTEM opcode and implement `CSRRW`/`CSRRS`/`CSRRC` and
their immediate forms. Traps need CSRs to be useful, so this pairs with step 1.

**3. `ECALL` / `EBREAK`.** Cheap once SYSTEM is decoded, and required for base
RV64I completeness.

**4. `FENCE`.** Can be a no-op on a single-hart in-order core, but it must at
least decode without faulting.

**5. Complete or drop Zbb.** Either implement the remaining ~13 instructions or
stop describing it as a B-extension.

Only after steps 1–4 would running
[riscv-arch-test](https://github.com/riscv-non-isa/riscv-arch-test) be meaningful.
That is the bar for the word "compliant."
