#!/usr/bin/env python3
"""
Generate ALU compliance vectors for tb_alu_compliance.v.

Semantics are written directly from the RISC-V spec (Vol I, unprivileged ISA):
RV64I base integer ops, RV64M multiply/divide (including the exact division-by-
zero and signed-overflow results the spec mandates), and the RV64 *W word ops
(which operate on the low 32 bits and sign-extend the 32-bit result).

Deliberately independent of alu.v -- that is the point.

Usage:
    python tools/gen_alu_vectors.py alu_vec.txt [count]

Output: one "funct3 funct7 is_word A B expected" hex tuple per line.
"""
import random
import sys

M64 = (1 << 64) - 1
M32 = (1 << 32) - 1
INT64_MIN = 1 << 63
INT32_MIN = 1 << 31


def s64(v):
    v &= M64
    return v - (1 << 64) if v >> 63 else v


def s32(v):
    v &= M32
    return v - (1 << 32) if v >> 31 else v


def sext32(v):
    """Sign-extend a 32-bit value to 64 bits."""
    return (v - (1 << 32) if (v & M32) >> 31 else v & M32) & M64


# funct7 encodings
F7_BASE, F7_SUB_SRA, F7_M = 0b0000000, 0b0100000, 0b0000001


def spec_alu(f3, f7, is_word, a, b):
    """Return the spec-mandated 64-bit result, or None if unmodeled."""
    a &= M64
    b &= M64

    # ---------------- RV64 word operations (*W) ----------------
    if is_word:
        aw, bw = a & M32, b & M32
        aws, bws = s32(aw), s32(bw)
        sh = b & 0x1F                       # word shifts use low 5 bits

        if f3 == 0b000:
            if f7 == F7_BASE:   return sext32((aw + bw) & M32)          # ADDW
            if f7 == F7_SUB_SRA:return sext32((aw - bw) & M32)          # SUBW
            if f7 == F7_M:      return sext32((aws * bws) & M32)        # MULW
        if f3 == 0b001 and f7 == F7_BASE:
            return sext32((aw << sh) & M32)                             # SLLW
        if f3 == 0b101:
            if f7 == F7_BASE:   return sext32(aw >> sh)                 # SRLW
            if f7 == F7_SUB_SRA:return sext32((aws >> sh) & M32)        # SRAW
            if f7 == F7_M:                                              # DIVUW
                return sext32(M32 if bw == 0 else (aw // bw) & M32)
        if f3 == 0b100 and f7 == F7_M:                                  # DIVW
            if bw == 0:                       return sext32(M32)
            if aw == INT32_MIN and bw == M32: return sext32(INT32_MIN)
            q = abs(aws) // abs(bws)
            if (aws < 0) != (bws < 0): q = -q
            return sext32(q & M32)
        if f3 == 0b110 and f7 == F7_M:                                  # REMW
            if bw == 0:                       return sext32(aw)
            if aw == INT32_MIN and bw == M32: return 0
            r = abs(aws) % abs(bws)
            if aws < 0: r = -r
            return sext32(r & M32)
        if f3 == 0b111 and f7 == F7_M:                                  # REMUW
            return sext32(aw if bw == 0 else (aw % bw) & M32)
        return None

    # ---------------- RV64M full width ----------------
    if f7 == F7_M:
        asg, bsg = s64(a), s64(b)
        if f3 == 0b000: return (asg * bsg) & M64                        # MUL
        if f3 == 0b001: return ((asg * bsg) >> 64) & M64                # MULH
        if f3 == 0b010: return ((asg * b) >> 64) & M64                  # MULHSU
        if f3 == 0b011: return ((a * b) >> 64) & M64                    # MULHU
        if f3 == 0b100:                                                 # DIV
            if b == 0:                              return M64
            if a == INT64_MIN and b == M64:         return INT64_MIN
            q = abs(asg) // abs(bsg)
            if (asg < 0) != (bsg < 0): q = -q
            return q & M64
        if f3 == 0b101:                                                 # DIVU
            return M64 if b == 0 else (a // b) & M64
        if f3 == 0b110:                                                 # REM
            if b == 0:                              return a
            if a == INT64_MIN and b == M64:         return 0
            r = abs(asg) % abs(bsg)
            if asg < 0: r = -r
            return r & M64
        if f3 == 0b111:                                                 # REMU
            return a if b == 0 else (a % b) & M64
        return None

    # ---------------- RV64I base ----------------
    sh = b & 0x3F                            # RV64 shifts use low 6 bits
    if f3 == 0b000:
        if f7 == F7_BASE:    return (a + b) & M64                       # ADD
        if f7 == F7_SUB_SRA: return (a - b) & M64                       # SUB
    if f3 == 0b001 and f7 == F7_BASE: return (a << sh) & M64            # SLL
    if f3 == 0b010: return 1 if s64(a) < s64(b) else 0                  # SLT
    if f3 == 0b011: return 1 if a < b else 0                            # SLTU
    if f3 == 0b100 and f7 == F7_BASE: return (a ^ b) & M64              # XOR
    if f3 == 0b101:
        if f7 == F7_BASE:    return (a >> sh) & M64                     # SRL
        if f7 == F7_SUB_SRA: return (s64(a) >> sh) & M64                # SRA
    if f3 == 0b110 and f7 == F7_BASE: return (a | b) & M64              # OR
    if f3 == 0b111 and f7 == F7_BASE: return (a & b) & M64              # AND
    return None


# (funct3, funct7, is_word) combinations the spec defines
CASES = [
    (0b000, F7_BASE, 0), (0b000, F7_SUB_SRA, 0), (0b001, F7_BASE, 0),
    (0b010, F7_BASE, 0), (0b011, F7_BASE, 0), (0b100, F7_BASE, 0),
    (0b101, F7_BASE, 0), (0b101, F7_SUB_SRA, 0), (0b110, F7_BASE, 0),
    (0b111, F7_BASE, 0),
    (0b000, F7_M, 0), (0b001, F7_M, 0), (0b010, F7_M, 0), (0b011, F7_M, 0),
    (0b100, F7_M, 0), (0b101, F7_M, 0), (0b110, F7_M, 0), (0b111, F7_M, 0),
    (0b000, F7_BASE, 1), (0b000, F7_SUB_SRA, 1), (0b000, F7_M, 1),
    (0b001, F7_BASE, 1), (0b101, F7_BASE, 1), (0b101, F7_SUB_SRA, 1),
    (0b101, F7_M, 1), (0b100, F7_M, 1), (0b110, F7_M, 1), (0b111, F7_M, 1),
]

# Values that break naive implementations.
EDGE = [
    0, 1, M64, 2, INT64_MIN, INT64_MIN - 1, M64 >> 1,
    INT32_MIN, M32, sext32(INT32_MIN), 0xFFFFFFFF_FFFFFFFF,
    0x8000000000000000, 0x7FFFFFFFFFFFFFFF, 63, 64, 31, 32,
]


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    outfile = sys.argv[1]
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 3000

    random.seed(11)
    out = []

    # Directed: every op against every edge-value pair.
    for (f3, f7, w) in CASES:
        for a in EDGE:
            for b in EDGE:
                e = spec_alu(f3, f7, w, a, b)
                if e is not None:
                    out.append((f3, f7, w, a & M64, b & M64, e))

    # Random fill.
    while len(out) < count:
        f3, f7, w = random.choice(CASES)
        a, b = random.getrandbits(64), random.getrandbits(64)
        e = spec_alu(f3, f7, w, a, b)
        if e is not None:
            out.append((f3, f7, w, a, b, e))

    with open(outfile, "w") as f:
        for f3, f7, w, a, b, e in out:
            f.write(f"{f3:01x} {f7:02x} {w:01x} {a:016x} {b:016x} {e:016x}\n")

    print(f"[OK] wrote {len(out)} vectors to {outfile}")


if __name__ == "__main__":
    main()
