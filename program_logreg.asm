# Logistic regression - binary classification on the ML accelerator.
#
# Rung 2 of ML_POST_ROADMAP.md. The dot product is IDENTICAL to linear
# regression; the only new thing is squashing the result into a probability:
#
#     z = w.x + b          <- accelerator does this, unchanged
#     y = sigmoid(z)       <- this is the new part
#
# THE PROBLEM: sigmoid(z) = 1 / (1 + e^-z) needs floating point and exp().
# This CPU has neither.
#
# TWO OBSERVATIONS MAKE IT TRACTABLE:
#
# 1. The CLASSIFICATION is free.
#        sigmoid(z) > 0.5   <=>   z > 0
#    So the class label is just a SIGN TEST on the accelerator's output. No
#    sigmoid needed at all. This is why logistic regression is barely harder
#    than linear regression on integer hardware.
#
# 2. The PROBABILITY comes from a LOOKUP TABLE.
#    sigmoid is precomputed at integer z in [-8, +8] and stored as Q8 fixed
#    point (256 = 1.0). Outside that range sigmoid is within 0.04% of 0 or 1,
#    so z is simply clamped. Inference = clamp, index, load.
#
# LUT (17 entries, Q8, z = -8 .. +8):
#     [0, 0, 1, 2, 5, 12, 31, 69, 128, 187, 225, 244, 251, 254, 255, 256, 256]
#      ^z=-8                        ^z=0                              ^z=+8
#
# Model: 8 features, int8 packed (one chunk).
#     w = [1, -1, 1, -1, 1, -1, 1, -1]
#     b = 0
#
#     x0: z = +4  ->  class 1,  P = 251/256
#     x1: z = -5  ->  class 0,  P =   2/256
#     x2: z = +1  ->  class 1,  P = 187/256
#     x3: z = -1  ->  class 0,  P =  69/256
#
#     positives = 2,  sum of P = 509   <- published (checks every LUT lookup)
#
# RAM layout (preloaded by the testbench):
#     0x000  w        1 chunk  (8 int8 packed)
#     0x008  x0..x3   4 chunks (8 int8 each)
#     0x100  LUT      17 int64 entries, index 0 = z of -8
#
# Accelerator registers (ML_BASE = 0x780) - see docs/ML_BLOCKS_EXPLAINED_4.md

# ---- register addresses ----
ADDI x10, x0, 1920          # 0x780  ML_CTRL
ADDI x11, x0, 1928          # 0x788  ML_STATUS
ADDI x14, x0, 1952          # 0x7A0  ML_ACC_LO
ADDI x15, x0, 1968          # 0x7B0  ML_LEN
ADDI x16, x0, 1976          # 0x7B8  ML_SRC_A
ADDI x17, x0, 1984          # 0x7C0  ML_SRC_B
ADDI x18, x0, 1992          # 0x7C8  ML_CNT

# ---- fixed accelerator config: w is always operand A, 1 chunk ----
ADDI x3, x0, 0
SD   x3, 0(x16)             # ML_SRC_A = 0x000 (the weight vector)
ADDI x3, x0, 1
SD   x3, 0(x18)             # ML_CNT = 1 doubleword
SD   x3, 0(x15)             # ML_LEN = 1 chunk (8 packed int8)

# ============================================================
# CLASSIFIER LOOP
#
#   x20 = count of positives
#   x21 = sum of probabilities (Q8)
#   x22 = address of the current sample (starts at 0x008, +8 each)
#   x23 = samples remaining
#   x24 = LUT base address (0x100 = 256)
# ============================================================
ADDI x20, x0, 0             # positives = 0
ADDI x21, x0, 0             # sum of P = 0
ADDI x22, x0, 8             # first sample at 0x008
ADDI x23, x0, 4             # 4 samples
ADDI x24, x0, 256           # LUT at 0x100

loop:
# ---- clear the accumulator ----
ADDI x5, x0, 2
SD   x5, 0(x10)

# ---- point the DMA at this sample ----
SD   x22, 0(x17)            # ML_SRC_B = current sample

# ---- fetch w and x ----
ADDI x6, x0, 128            # dma
SD   x6, 0(x10)
dma_wait:
LD   x7, 0(x11)
ANDI x7, x7, 1
BNE  x7, x0, dma_wait

# ---- z = w.x  (LANE_8 packed, OP_DOT, signed) ----
# 0x01 start | 0x04 signed | (0<<3) LANE_8 | (1<<5) OP_DOT = 0x25 = 37
ADDI x6, x0, 37
SD   x6, 0(x10)
poll:
LD   x7, 0(x11)
ANDI x7, x7, 2
BEQ  x7, x0, poll

LD   x8, 0(x14)             # x8 = z  (bias is 0, so z = w.x)

# ============================================================
# 1. CLASSIFY - just a sign test.
#
#    sigmoid(z) > 0.5  <=>  z > 0
#    No sigmoid required. This is the whole classification.
# ============================================================
BLT  x8, x0, negative       # z < 0  ->  class 0
ADDI x20, x20, 1            # z > 0  ->  class 1, count it
negative:

# ============================================================
# 2. PROBABILITY - clamp z to [-8, +8], then index the LUT.
# ============================================================
ADDI x9, x0, -8
BLT  x8, x9, clamp_lo       # z < -8 ?
ADDI x9, x0, 8
BLT  x9, x8, clamp_hi       # z > +8 ?
JAL  x0, in_range

clamp_lo:
ADDI x8, x0, -8
JAL  x0, in_range

clamp_hi:
ADDI x8, x0, 8

in_range:
# LUT index = z + 8   (so z=-8 maps to entry 0)
ADDI x8, x8, 8
SLLI x8, x8, 3              # x8 = index * 8 bytes
ADD  x8, x8, x24            # + LUT base
LD   x9, 0(x8)              # x9 = P(y=1) in Q8

ADD  x21, x21, x9           # sum of probabilities

# ---- next sample ----
ADDI x22, x22, 8            # advance one chunk (8 bytes)
ADDI x23, x23, -1
BNE  x23, x0, loop

# ============================================================
# Publish the sum of probabilities (expect 509).
#
# This is a stronger check than the class count: it depends on EVERY LUT
# lookup being correct, not just the sign of each z.
# ============================================================
ADDI x25, x0, 2040          # 0x7F8 out_port
SD   x21, 0(x25)

halt:
JAL  x0, halt
