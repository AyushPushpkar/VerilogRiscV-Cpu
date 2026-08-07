#!/usr/bin/env python3
"""
Generate immediate-generator compliance vectors for tb_imm_compliance.v.

The immediate decoding here is written directly from the RISC-V spec
(Vol I, unprivileged ISA, Fig 2.4 "RISC-V base instruction formats showing
immediate variants"). It deliberately does NOT import assembler.py or read
any RTL -- the whole point is to be an independent check on imm_gen.v.

Usage:
    python tools/gen_imm_vectors.py imm_vec.txt [count]

Output format: one "instruction expected_imm" hex pair per line.
"""
import random
import sys

XLEN_MASK = (1 << 64) - 1


def bits(w, hi, lo):
    return (w >> lo) & ((1 << (hi - lo + 1)) - 1)


def sign_extend(v, n):
    """Sign-extend an n-bit value to a Python int."""
    return v - (1 << n) if (v >> (n - 1)) & 1 else v


# Opcodes that carry an immediate.
OP_LOAD, OP_IMM, OP_IMM_32, OP_JALR = 0b0000011, 0b0010011, 0b0011011, 0b1100111
OP_STORE, OP_BRANCH = 0b0100011, 0b1100011
OP_LUI, OP_AUIPC, OP_JAL = 0b0110111, 0b0010111, 0b1101111

I_TYPE = (OP_LOAD, OP_IMM, OP_IMM_32, OP_JALR)
U_TYPE = (OP_LUI, OP_AUIPC)

ALL_OPS = I_TYPE + (OP_STORE, OP_BRANCH) + U_TYPE + (OP_JAL,)


def spec_immediate(w):
    """Decode the immediate for instruction word w, per the spec."""
    op = bits(w, 6, 0)

    # I-type: imm[11:0] = inst[31:20]
    if op in I_TYPE:
        return sign_extend(bits(w, 31, 20), 12)

    # S-type: imm[11:5] = inst[31:25], imm[4:0] = inst[11:7]
    if op == OP_STORE:
        return sign_extend((bits(w, 31, 25) << 5) | bits(w, 11, 7), 12)

    # B-type: imm[12|10:5] = inst[31|30:25], imm[4:1|11] = inst[11:8|7], imm[0]=0
    if op == OP_BRANCH:
        v = ((bits(w, 31, 31) << 12) | (bits(w, 7, 7) << 11) |
             (bits(w, 30, 25) << 5) | (bits(w, 11, 8) << 1))
        return sign_extend(v, 13)

    # U-type: imm[31:12] = inst[31:12], low 12 bits zero. Sign-extended to XLEN.
    if op in U_TYPE:
        return sign_extend(bits(w, 31, 12) << 12, 32)

    # J-type: imm[20|10:1|11|19:12] = inst[31|30:21|20|19:12], imm[0]=0
    if op == OP_JAL:
        v = ((bits(w, 31, 31) << 20) | (bits(w, 19, 12) << 12) |
             (bits(w, 20, 20) << 11) | (bits(w, 30, 21) << 1))
        return sign_extend(v, 21)

    return 0


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    outfile = sys.argv[1]
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 400

    random.seed(7)  # deterministic: same vectors every run

    lines = []

    # Directed edge cases first: all-zero and all-one immediate fields exercise
    # the sign-extension boundary, which is where imm_gen bugs actually live.
    for op in ALL_OPS:
        for pattern in (0x00000000, 0xFFFFFF80, 0x80000000, 0x7FFFFF80):
            w = (pattern & ~0x7F) | op
            lines.append((w, spec_immediate(w) & XLEN_MASK))

    # Then random fill.
    while len(lines) < count:
        op = random.choice(ALL_OPS)
        w = (random.getrandbits(25) << 7) | op
        lines.append((w, spec_immediate(w) & XLEN_MASK))

    with open(outfile, "w") as f:
        for w, e in lines:
            f.write(f"{w:08x} {e:016x}\n")

    print(f"[OK] wrote {len(lines)} vectors to {outfile}")


if __name__ == "__main__":
    main()
