# Linear regression inference on the ML accelerator.
#
# The first REAL machine-learning workload on this hardware. Everything before
# this was synthetic vectors and toy matrices.
#
# ML_POST_ROADMAP.md ranks linear regression first: "mostly dot products and
# scalar math, small code size, easy to verify." That is exactly what this is -
# a prediction is one dot product plus a bias:
#
#     y = w . x + b
#
# This runs INFERENCE with a pre-trained model (training needs division and
# multiple passes; inference is the honest first target).
#
# Trained 4-feature model:
#     w = [3, -2, 5, 1]     weights
#     b = 10                bias
#
# Batch of 4 samples:
#     x0 = [1, 2, 3, 4]  ->  dot=18  ->  y=28
#     x1 = [2, 0, 1, 5]  ->  dot=16  ->  y=26
#     x2 = [0, 4, 2, 1]  ->  dot= 3  ->  y=13
#     x3 = [5, 5, 0, 0]  ->  dot= 5  ->  y=15
#
#     sum of predictions = 82   <- published to out_port
#
# THE LOOP IS THE POINT. Each iteration re-points the DMA at the next sample and
# fires one dot product. The weight vector stays in RAM, untouched - it is
# fetched fresh by the DMA each time, costing zero software stores.
#
# RAM layout (int64 elements, 8 bytes each):
#     0x000  w  = [3, -2, 5, 1]
#     0x020  x0 = [1, 2, 3, 4]
#     0x040  x1 = [2, 0, 1, 5]
#     0x060  x2 = [0, 4, 2, 1]
#     0x080  x3 = [5, 5, 0, 0]
#
# Accelerator registers (ML_BASE = 0x780):
#     0x780  ML_CTRL    [0]start [1]clear [2]signed [4:3]lanes [6:5]op [7]dma
#     0x788  ML_STATUS  [0]busy [1]done
#     0x7A0  ML_ACC_LO  result
#     0x7B0  ML_LEN     vector length
#     0x7B8  ML_SRC_A   DMA source A
#     0x7C0  ML_SRC_B   DMA source B
#     0x7C8  ML_CNT     doublewords per operand

# ============================================================
# Register addresses
# ============================================================
ADDI x10, x0, 1920          # 0x780  ML_CTRL
ADDI x11, x0, 1928          # 0x788  ML_STATUS
ADDI x14, x0, 1952          # 0x7A0  ML_ACC_LO
ADDI x15, x0, 1968          # 0x7B0  ML_LEN
ADDI x16, x0, 1976          # 0x7B8  ML_SRC_A
ADDI x17, x0, 1984          # 0x7C0  ML_SRC_B
ADDI x18, x0, 1992          # 0x7C8  ML_CNT

# ============================================================
# Load the model and the data into RAM.
#
# In a real system this is the trained model arriving from somewhere - it is
# SETUP, not per-inference cost. Note that once it is here, the DMA reads it
# every iteration without software touching it again.
# ============================================================

# ---- w = [3, -2, 5, 1] at 0x000 ----
ADDI x1, x0, 3
SD   x1, 0(x0)
ADDI x1, x0, -2
SD   x1, 8(x0)
ADDI x1, x0, 5
SD   x1, 16(x0)
ADDI x1, x0, 1
SD   x1, 24(x0)

# ---- x0 = [1, 2, 3, 4] at 0x020 (32) ----
ADDI x1, x0, 1
SD   x1, 32(x0)
ADDI x1, x0, 2
SD   x1, 40(x0)
ADDI x1, x0, 3
SD   x1, 48(x0)
ADDI x1, x0, 4
SD   x1, 56(x0)

# ---- x1 = [2, 0, 1, 5] at 0x040 (64) ----
ADDI x1, x0, 2
SD   x1, 64(x0)
SD   x0, 72(x0)             # 0
ADDI x1, x0, 1
SD   x1, 80(x0)
ADDI x1, x0, 5
SD   x1, 88(x0)

# ---- x2 = [0, 4, 2, 1] at 0x060 (96) ----
SD   x0, 96(x0)             # 0
ADDI x1, x0, 4
SD   x1, 104(x0)
ADDI x1, x0, 2
SD   x1, 112(x0)
ADDI x1, x0, 1
SD   x1, 120(x0)

# ---- x3 = [5, 5, 0, 0] at 0x080 (128) ----
ADDI x1, x0, 5
SD   x1, 128(x0)
SD   x1, 136(x0)
SD   x0, 144(x0)            # 0
SD   x0, 152(x0)            # 0

# ============================================================
# Fixed accelerator configuration - set once, reused every iteration.
# ============================================================
ADDI x3, x0, 0
SD   x3, 0(x16)             # ML_SRC_A = 0x000, the weight vector w
ADDI x3, x0, 4
SD   x3, 0(x18)             # ML_CNT = 4 elements
SD   x3, 0(x15)             # ML_LEN = 4

# ============================================================
# INFERENCE LOOP
#
#   x20 = accumulated sum of predictions
#   x21 = address of the current sample (starts at 0x020, +32 each time)
#   x22 = samples remaining
#   x23 = bias (10)
# ============================================================
ADDI x20, x0, 0             # sum = 0
ADDI x21, x0, 32            # first sample at 0x020
ADDI x22, x0, 4             # 4 samples
ADDI x23, x0, 10            # bias

loop:
# ---- clear the accumulator ----
ADDI x5, x0, 2
SD   x5, 0(x10)

# ---- point the DMA at this sample; w stays at ML_SRC_A ----
SD   x21, 0(x17)            # ML_SRC_B = current sample address

# ---- fetch: one store pulls w and x out of RAM (8 elements) ----
ADDI x6, x0, 128            # bit 7 = dma
SD   x6, 0(x10)

dma_wait:
LD   x7, 0(x11)
ANDI x7, x7, 1              # busy?
BNE  x7, x0, dma_wait

# ---- run the dot product: start | signed | LANE_64 | OP_DOT ----
# 0x01 | 0x04 | (3<<3)=0x18 | (1<<5)=0x20  =  0x3D = 61
ADDI x6, x0, 61
SD   x6, 0(x10)

poll:
LD   x7, 0(x11)
ANDI x7, x7, 2              # done?
BEQ  x7, x0, poll

# ---- y = dot + b, accumulate into the running sum ----
LD   x8, 0(x14)             # ML_ACC_LO = w . x
ADD  x8, x8, x23            # + bias
ADD  x20, x20, x8           # sum += y

# ---- next sample ----
ADDI x21, x21, 32           # advance 4 elements * 8 bytes
ADDI x22, x22, -1
BNE  x22, x0, loop

# ============================================================
# Publish the sum of predictions (expect 82).
# ============================================================
ADDI x25, x0, 2040          # 0x7F8 out_port
SD   x20, 0(x25)

halt:
JAL  x0, halt
