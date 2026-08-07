# Matrix multiply on the ML accelerator, driven by the CPU.
#
# Computes a full 2x2 GEMM in hardware from a single `start`. Before the
# dot_product/matrix_tile engines were wired to the bus, software had to run the
# accumulate loop itself; now it fills the operand buffer and lets the engine go.
#
#   A = [1 2]   B = [5 6]   C = A x B = [19 22]
#       [3 4]       [7 8]               [43 50]
#
# Publishes the sum of C (19+22+43+50 = 134) to out_port, so there is one
# observable value that could only be right if every element is right.
#
# Accelerator registers (ML_BASE = 0xC0, 8-byte spaced):
#   0x780  ML_CTRL    W   [0]=start [1]=clear [2]=signed [4:3]=lanes [6:5]=op
#   0x788  ML_STATUS  R   [0]=busy [1]=done
#   0x790  ML_A       W   append to operand buffer A
#   0x798  ML_B       W   append to operand buffer B
#   0x7A0  ML_ACC_LO  R   read result (advances the C read pointer in MAT mode)
#   0x7B0  ML_LEN     W   [7:0]=M [15:8]=N [23:16]=K
#
# op = 2 (OP_MAT), lane_mode = 3 (int64, 1 lane per element).
#   clear  = 0x02
#   start  = 0x01 | signed 0x04 | lanes(3)<<3 = 0x18 | op(2)<<5 = 0x40
#          = 0x5D
#   B is stored COLUMN-major so a column slice is contiguous in the buffer.

# ---- register addresses ----
ADDI x10, x0, 1920           # 0x780  ML_CTRL
ADDI x11, x0, 1928           # 0x788  ML_STATUS
ADDI x12, x0, 1936           # 0x790  ML_A
ADDI x13, x0, 1944           # 0x798  ML_B
ADDI x14, x0, 1952           # 0x7A0  ML_ACC_LO
ADDI x15, x0, 1968           # 0x7B0  ML_LEN

# ---- clear: zeroes the accumulator AND the buffer fill pointers ----
ADDI x5, x0, 2
SD   x5, 0(x10)

# ---- fill buffer A: row-major [1, 2, 3, 4] ----
ADDI x1, x0, 1
SD   x1, 0(x12)
ADDI x1, x0, 2
SD   x1, 0(x12)
ADDI x1, x0, 3
SD   x1, 0(x12)
ADDI x1, x0, 4
SD   x1, 0(x12)

# ---- fill buffer B: COLUMN-major.  col0 = [5,7], col1 = [6,8] ----
ADDI x1, x0, 5
SD   x1, 0(x13)
ADDI x1, x0, 7
SD   x1, 0(x13)
ADDI x1, x0, 6
SD   x1, 0(x13)
ADDI x1, x0, 8
SD   x1, 0(x13)

# ---- dims: M=2 (bits 7:0), N=2 (bits 15:8), K=2 (bits 23:16) ----
# Build 0x020202 = (2 << 16) | (2 << 8) | 2, one byte at a time, because
# ADDI only carries a 12-bit immediate.
ADDI x2, x0, 2
SLLI x2, x2, 8
ADDI x2, x2, 2
SLLI x2, x2, 8
ADDI x2, x2, 2              # x2 = 0x020202
SD   x2, 0(x15)             # ML_LEN

# ---- start the GEMM: one store runs the whole matrix multiply ----
ADDI x6, x0, 93             # 0x5D = start | signed | LANE_64 | OP_MAT
SD   x6, 0(x10)

# ---- poll ML_STATUS until done (bit 1) ----
poll:
LD   x7, 0(x11)
ANDI x7, x7, 2              # isolate the done bit
BEQ  x7, x0, poll

# ---- read C back: each load advances the read pointer ----
LD   x20, 0(x14)            # C[0][0] = 19
LD   x21, 0(x14)            # C[0][1] = 22
LD   x22, 0(x14)            # C[1][0] = 43
LD   x23, 0(x14)            # C[1][1] = 50

# ---- sum them: 19 + 22 + 43 + 50 = 134 ----
ADD  x24, x20, x21
ADD  x24, x24, x22
ADD  x24, x24, x23

# ---- publish ----
ADDI x25, x0, 2040           # 0x7F8 out_port
SD   x24, 0(x25)

halt:
JAL  x0, halt
