#!/usr/bin/env python3
"""
Generate branch-comparison compliance vectors for tb_branch_compliance.v.

Semantics from the RISC-V spec (Vol I, unprivileged ISA, "Conditional
Branches"). The subtlety these vectors target:

    BLT / BGE   compare as SIGNED
    BLTU / BGEU compare as UNSIGNED

The same 64 bits compare differently under the two interpretations - e.g.
0xFFFF...FF is -1 signed (less than 1) but 2^64-1 unsigned (greater than 1).
An implementation that wires the wrong comparator passes every non-negative
test and fails only on negatives, so the vectors below deliberately straddle
the sign boundary.

Independent of cpu_top.v / alu.v by construction.

Usage:
    python tools/gen_branch_vectors.py branch_vec.txt [count]

Output: "funct3 A B taken" per line.
"""
import random
import sys

M64 = (1 << 64) - 1


def s64(v):
    v &= M64
    return v - (1 << 64) if v >> 63 else v


BR_BEQ, BR_BNE = 0b000, 0b001
BR_BLT, BR_BGE = 0b100, 0b101
BR_BLTU, BR_BGEU = 0b110, 0b111

ALL = [BR_BEQ, BR_BNE, BR_BLT, BR_BGE, BR_BLTU, BR_BGEU]


def spec_taken(f3, a, b):
    a &= M64
    b &= M64
    if f3 == BR_BEQ:  return a == b
    if f3 == BR_BNE:  return a != b
    if f3 == BR_BLT:  return s64(a) < s64(b)     # signed
    if f3 == BR_BGE:  return s64(a) >= s64(b)    # signed
    if f3 == BR_BLTU: return a < b               # unsigned
    if f3 == BR_BGEU: return a >= b              # unsigned
    return False


# Values chosen so signed and unsigned comparison DISAGREE.
EDGE = [
    0, 1, 2,
    M64,                        # -1 signed, 2^64-1 unsigned
    M64 - 1,                    # -2 signed
    1 << 63,                    # INT64_MIN signed, 2^63 unsigned
    (1 << 63) - 1,              # INT64_MAX
    (1 << 63) + 1,              # INT64_MIN+1
    0x7FFFFFFFFFFFFFFF,
    0x8000000000000000,
    0xFFFFFFFF,                 # positive in 64-bit
    0xFFFFFFFF00000000,         # negative in 64-bit
]


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    outfile = sys.argv[1]
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 1200

    random.seed(13)
    out = []

    # Directed: every branch op against every edge pair.
    for f3 in ALL:
        for a in EDGE:
            for b in EDGE:
                out.append((f3, a & M64, b & M64, 1 if spec_taken(f3, a, b) else 0))

    # Random fill, biased toward values with the sign bit set.
    while len(out) < count:
        f3 = random.choice(ALL)
        a = random.getrandbits(64)
        b = random.getrandbits(64)
        if random.random() < 0.3:
            b = a                      # exercise equality paths
        out.append((f3, a, b, 1 if spec_taken(f3, a, b) else 0))

    with open(outfile, "w") as f:
        for f3, a, b, t in out:
            f.write(f"{f3:01x} {a:016x} {b:016x} {t:016x}\n")

    print(f"[OK] wrote {len(out)} vectors to {outfile}")


if __name__ == "__main__":
    main()
