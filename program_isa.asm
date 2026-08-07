# RV64I ISA compliance program.
#
# Exercises the pieces that unit tests can miss because they only show up when
# the full datapath is wired together: LUI/AUIPC sign extension, signed vs
# unsigned branch comparison, and load sign extension.
#
# Each check that fails jumps to `fail`, which publishes 0 to out_port.
# If every check passes, the program publishes 0x555 (1365) and halts.
#
# out_port = 0xF8 (MMIO_ADDRESS, 8-byte aligned).

# ============================================================
# 1. LUI sign extension (the RV64 trap)
#
#    LUI 0x80000 loads 0x80000 into bits [31:12], giving the 32-bit
#    value 0x80000000, which RV64 SIGN-EXTENDS to 0xFFFFFFFF_80000000.
#    An RV32-derived implementation would zero-extend and get it wrong.
#
#    Check: the result must be NEGATIVE.
# ============================================================
LUI  x1, 0x80000            # x1 = 0xFFFFFFFF_80000000 (negative)
BGE  x1, x0, fail           # if x1 >= 0, sign extension is broken

# LUI with a positive immediate must stay positive.
LUI  x2, 0x00001            # x2 = 0x0000000000001000
BLT  x2, x0, fail           # must NOT be negative

# ============================================================
# 2. Signed vs unsigned branch comparison
#
#    x3 = -1. As a SIGNED value it is less than 1.
#    As an UNSIGNED value it is 2^64-1, which is greater than 1.
#    Getting these backwards is the classic branch bug.
# ============================================================
ADDI x3, x0, -1             # x3 = 0xFFFFFFFF_FFFFFFFF
ADDI x4, x0, 1              # x4 = 1

BLT  x3, x4, signed_ok      # signed: -1 < 1  -> MUST take
JAL  x0, fail               # not taken = signed compare is broken

signed_ok:
BLTU x4, x3, unsigned_ok    # unsigned: 1 < 2^64-1 -> MUST take
JAL  x0, fail

unsigned_ok:
# The inverse must NOT be taken.
BLTU x3, x4, fail           # unsigned: 2^64-1 < 1 is FALSE
BLT  x4, x3, fail           # signed:   1 < -1     is FALSE

# BGE / BGEU with the same operands
BGE  x4, x3, bge_ok         # signed: 1 >= -1 -> MUST take
JAL  x0, fail

bge_ok:
BGEU x3, x4, bgeu_ok        # unsigned: 2^64-1 >= 1 -> MUST take
JAL  x0, fail

bgeu_ok:

# ============================================================
# 3. Load sign extension
#
#    Store 0xFF as a byte, then load it two ways:
#      LB  -> -1   (sign-extended)
#      LBU -> +255 (zero-extended)
# ============================================================
ADDI x5, x0, 255            # x5 = 0xFF
SB   x5, 0(x0)              # MEM[0] = 0xFF

LB   x6, 0(x0)              # x6 must be -1
BGE  x6, x0, fail           # if LB result >= 0, sign extension is broken

LBU  x7, 0(x0)              # x7 must be +255
BLT  x7, x0, fail           # must NOT be negative

ADDI x8, x0, 255
BNE  x7, x8, fail           # LBU must equal exactly 255

# ============================================================
# 4. x0 is hardwired to zero
#
#    Writing to x0 must be silently discarded.
# ============================================================
ADDI x0, x0, 99             # attempt to write x0
BNE  x0, x0, fail           # x0 must still equal itself
ADDI x9, x0, 0
BNE  x9, x0, fail           # reading x0 must give 0

# ============================================================
# All checks passed.
# ============================================================
pass:
ADDI x20, x0, 1365          # success sentinel = 0x555
ADDI x21, x0, 2040           # out_port (0x7F8)
SD   x20, 0(x21)
JAL  x0, done

fail:
ADDI x20, x0, 0             # failure sentinel
ADDI x21, x0, 2040
SD   x20, 0(x21)

done:
JAL  x0, done
