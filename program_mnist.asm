# MNIST-scale linear regression: 784 features, int8 packed, SOFTWARE TILED.
#
# This is the last piece. 784 features (a 28x28 image) is 98 packed chunks, but
# the operand buffer only holds 64. So the vector does not fit - it must be
# processed in TILES:
#
#     tile 0:  chunks  0..63   (512 features)   accumulate = 0  (start fresh)
#     tile 1:  chunks 64..97   (272 features)   accumulate = 1  (ADD to it)
#
# The partial sums add up inside the 128-bit accumulator. They are never rounded
# and never round-tripped through a 64-bit CPU register - which is the whole
# point of having a widened accumulator.
#
# ML_CTRL[8] = accumulate. Without it every start wiped the previous tile and
# tiling was impossible.
#
# Model (preloaded into RAM by the testbench, as a real system would receive it):
#     w = [(i%7)-3 for i in 0..783]     weights
#     x = [(i%5)+1 for i in 0..783]     one image, flattened
#     b = 1000                           bias
#
#     w.x = 1
#     y   = 1 + 1000 = 1001              <- published to out_port
#
# RAM layout (int8 packed, 8 features per doubleword):
#     0x000  w = 98 doublewords = 784 bytes
#     0x310  x = 98 doublewords = 784 bytes
#
# Cost:
#     scalar       ~3136 instructions   (4 per feature)
#     accelerator     35 instructions   (constant - 2 tiles worth of handshake)
#     compute         98 cycles         (vs 784 scalar MACs)

# ---- register addresses ----
ADDI x10, x0, 1920          # 0x780  ML_CTRL
ADDI x11, x0, 1928          # 0x788  ML_STATUS
ADDI x14, x0, 1952          # 0x7A0  ML_ACC_LO
ADDI x15, x0, 1968          # 0x7B0  ML_LEN
ADDI x16, x0, 1976          # 0x7B8  ML_SRC_A
ADDI x17, x0, 1984          # 0x7C0  ML_SRC_B
ADDI x18, x0, 1992          # 0x7C8  ML_CNT

# ---- clear the accumulator once, before the first tile ----
ADDI x5, x0, 2
SD   x5, 0(x10)

# ============================================================
# TILE 0: chunks 0..63  (512 features)
#
#   w tile at 0x000, x tile at 0x310 (784)
#   accumulate = 0  ->  start from zero
# ============================================================
ADDI x3, x0, 0
SD   x3, 0(x16)             # ML_SRC_A = w + 0
ADDI x3, x0, 784
SD   x3, 0(x17)             # ML_SRC_B = x + 0

ADDI x3, x0, 64             # 64 chunks
SD   x3, 0(x18)             # ML_CNT = 64 doublewords
SD   x3, 0(x15)             # ML_LEN = 64 chunks

# fetch
ADDI x6, x0, 128            # dma
SD   x6, 0(x10)
wait0:
LD   x7, 0(x11)
ANDI x7, x7, 1
BNE  x7, x0, wait0

# run: start | signed | LANE_8 | OP_DOT, accumulate = 0
#   0x01 | 0x04 | (0<<3) | (1<<5) = 0x25 = 37
ADDI x6, x0, 37
SD   x6, 0(x10)
poll0:
LD   x7, 0(x11)
ANDI x7, x7, 2
BEQ  x7, x0, poll0

# ============================================================
# TILE 1: chunks 64..97  (272 features)
#
#   w tile at 0x000 + 64*8 = 512
#   x tile at 0x310 + 64*8 = 1296
#   accumulate = 1  ->  ADD to the running total
# ============================================================
ADDI x3, x0, 512
SD   x3, 0(x16)             # ML_SRC_A = w + 512
ADDI x3, x0, 1296
SD   x3, 0(x17)             # ML_SRC_B = x + 512

ADDI x3, x0, 34             # 34 remaining chunks
SD   x3, 0(x18)             # ML_CNT = 34
SD   x3, 0(x15)             # ML_LEN = 34

# fetch
ADDI x6, x0, 128            # dma
SD   x6, 0(x10)
wait1:
LD   x7, 0(x11)
ANDI x7, x7, 1
BNE  x7, x0, wait1

# run with ACCUMULATE set:
#   0x25 | (1<<8) = 0x125 = 293
ADDI x6, x0, 293
SD   x6, 0(x10)
poll1:
LD   x7, 0(x11)
ANDI x7, x7, 2
BEQ  x7, x0, poll1

# ============================================================
# y = w.x + b   (the accumulator holds the sum of BOTH tiles)
# ============================================================
LD   x20, 0(x14)            # ML_ACC_LO = w.x  (expect 1)
ADDI x20, x20, 1000         # + bias           (expect 1001)

ADDI x25, x0, 2040          # 0x7F8 out_port
SD   x20, 0(x25)

halt:
JAL  x0, halt
