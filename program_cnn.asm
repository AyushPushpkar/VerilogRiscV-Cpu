# Small CNN: 4x4 image * 3x3 filter -> 2x2 feature map -> ReLU.
#
# Rung 6 of ML_POST_ROADMAP.md. See docs/CNN_DESIGN.md for the full design.
#
# THE IDEA: a convolution is a sliding dot product. Each output pixel is the dot
# product of the 3x3 filter with the 3x3 image window under it. Flatten both to
# 9-vectors and it is exactly what the accelerator does.
#
# WEIGHT REUSE - the defining property of a CNN: the SAME filter is dotted
# against every window. On this accelerator that is OP_MAT with N=1, where
# operand B (the filter) is read once per output and reused across all M rows.
#
#   A = the 4 windows  (the "matrix", one row per output)   operand A
#   B = the filter     (the reused vector)                  operand B
#   M=4, N=1, K=9
#
# im2col (flattening the windows) is done by the testbench - it is data prep, not
# the convolution. This program drives the accelerator and applies ReLU.
#
# K=9 at LANE_8 spans 2 chunks (16 slots, 7 padding zeros). Padding contributes
# 0*0=0, so it is invisible. matrix_tile already handles this (tb_matrix_tile
# tests exactly K=9).
#
#   conv outputs = [-11, -1, -6, 4]
#   after ReLU   = [  0,  0,  0, 4]     <- 3 of 4 clamped, ReLU is load-bearing
#   sum          = 4                    <- published
#   (without ReLU: -14)
#
# RAM layout (written by the testbench):
#   0x000  A: 4 windows, each 16 int8 (9 real + 7 pad) = 8 doublewords
#   0x040  B: filter, 16 int8 = 2 doublewords
#   0x060  feature map results, written back here
#
# Accelerator registers: see docs/ML_BLOCKS_EXPLAINED_5.md

ADDI x10, x0, 1920          # 0x780  ML_CTRL
ADDI x11, x0, 1928          # 0x788  ML_STATUS
ADDI x14, x0, 1952          # 0x7A0  ML_ACC_LO
ADDI x15, x0, 1968          # 0x7B0  ML_LEN
ADDI x16, x0, 1976          # 0x7B8  ML_SRC_A
ADDI x17, x0, 1984          # 0x7C0  ML_SRC_B
ADDI x18, x0, 1992          # 0x7C8  ML_CNT

# ============================================================
# CONVOLUTION: all 4 outputs in ONE OP_MAT run.
# ============================================================
ADDI x5, x0, 2
SD   x5, 0(x10)             # clear

ADDI x3, x0, 0
SD   x3, 0(x16)             # ML_SRC_A = 0x000 (the 4 windows)
ADDI x3, x0, 64
SD   x3, 0(x17)             # ML_SRC_B = 0x040 (the filter)

# ML_CNT: A = 8 chunks (4 windows x 2), B = 2 chunks.
#   (2 << 16) | 8 = 0x20008 = 131080
ADDI x3, x0, 2
SLLI x3, x3, 16
ADDI x3, x3, 8
SD   x3, 0(x18)

# ML_LEN: M=4, N=1, K=9  ->  (9<<16)|(1<<8)|4 = 0x090104
ADDI x4, x0, 9
SLLI x4, x4, 8
ADDI x4, x4, 1
SLLI x4, x4, 8
ADDI x4, x4, 4              # x4 = 0x090104
SD   x4, 0(x15)

# fetch both operands
ADDI x6, x0, 128            # dma
SD   x6, 0(x10)
cnn_dma:
LD   x7, 0(x11)
ANDI x7, x7, 1
BNE  x7, x0, cnn_dma

# run: start | signed | LANE_8 | OP_MAT
#   0x01 | 0x04 | (0<<3) | (2<<5) = 0x45 = 69
ADDI x6, x0, 69
SD   x6, 0(x10)
cnn_poll:
LD   x7, 0(x11)
ANDI x7, x7, 2
BEQ  x7, x0, cnn_poll

# ============================================================
# Read the 4 conv outputs, apply ReLU, accumulate the sum, and
# write each ReLU'd value to the feature-map area at 0x060.
#
#   x20 = running sum
#   x27 = feature-map write address (0x060, +8 each)
#   x28 = outputs remaining
# ============================================================
ADDI x20, x0, 0            # sum = 0
ADDI x27, x0, 96           # 0x060
ADDI x28, x0, 4            # 4 outputs

relu_loop:
LD   x8, 0(x14)            # next conv output (ML_ACC_LO auto-advances)

# ReLU: max(0, x8). One branch.
BGE  x8, x0, keep
ADDI x8, x0, 0
keep:

SD   x8, 0(x27)           # store into the feature map
ADD  x20, x20, x8         # sum += relu(out)

ADDI x27, x27, 8
ADDI x28, x28, -1
BNE  x28, x0, relu_loop

# ---- publish the feature-map sum (expect 4) ----
ADDI x25, x0, 2040        # 0x7F8 out_port
SD   x20, 0(x25)

halt:
JAL  x0, halt
