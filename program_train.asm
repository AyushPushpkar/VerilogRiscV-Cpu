# TRAINING: linear regression learned by gradient descent.
#
# Everything before this was INFERENCE - running a model someone else trained.
# This program LEARNS the weights from data, on the accelerator, in integer
# arithmetic.
#
#   prediction:  y_hat = w . x          <- the accelerator does this
#   error:       e     = y_hat - y
#   gradient:    g[i]  = e * x[i]
#   update:      w[i] -= g[i] >> SHIFT  <- learning rate = 1/2^SHIFT
#
# NO DIVISION NEEDED. The learning rate is a RIGHT SHIFT. (RV64M does have
# division, but a shift is one cycle and exact.)
#
# THE HARD PART: integer truncation kills learning.
#
# The obvious implementation stalls. Once the gradient is smaller than 1, the
# shift truncates it to ZERO and the weights stop moving - the loss plateaus
# well short of the answer. I hit this: loss dropped 83 -> 17 and then stuck
# forever.
#
# THE FIX: keep the weights AND the error in Q8 fixed point (256 = 1.0).
#
#   pred_q = w_q . x                (Q8, do NOT truncate)
#   err_q  = pred_q - (y << 8)      (Q8)
#   w_q[i] -= (err_q * x[i]) >> SHIFT
#
# Because the error stays scaled, a gradient of "0.3" is 77 in Q8 - still big
# enough to move the weight. Truncating the prediction to an integer first is
# what breaks it.
#
# TASK: learn w = [3, -2, 1, 4] from 4 samples, starting from w = [0,0,0,0].
#
#   x0 = [1,2,1,1]  ->  y = 4
#   x1 = [2,1,0,1]  ->  y = 8
#   x2 = [1,0,2,1]  ->  y = 9
#   x3 = [0,1,1,2]  ->  y = 7
#
#   After 150 epochs the weights converge EXACTLY to [3,-2,1,4], loss = 0.
#
# The program publishes the learned weights packed as int8, so the testbench can
# check every one.
#
# RAM layout:
#   0x000  x0..x3   4 samples, one int8-packed chunk each  (0x000-0x018)
#   0x020  y0..y3   4 targets, int64                        (0x020-0x038)
#   0x040  w_q      4 weights in Q8, int64                  (0x040-0x058)
#   0x060  w_pack   the learned weights, packed int8        (written at the end)

# ---- accelerator registers ----
ADDI x10, x0, 1920          # 0x780  ML_CTRL
ADDI x11, x0, 1928          # 0x788  ML_STATUS
ADDI x14, x0, 1952          # 0x7A0  ML_ACC_LO
ADDI x15, x0, 1968          # 0x7B0  ML_LEN
ADDI x16, x0, 1976          # 0x7B8  ML_SRC_A
ADDI x17, x0, 1984          # 0x7C0  ML_SRC_B
ADDI x18, x0, 1992          # 0x7C8  ML_CNT

# ---- initialise the weights to zero (Q8) ----
SD   x0, 64(x0)             # w_q[0] = 0
SD   x0, 72(x0)             # w_q[1] = 0
SD   x0, 80(x0)             # w_q[2] = 0
SD   x0, 88(x0)             # w_q[3] = 0

# ============================================================
# TRAINING LOOP
#
#   x24 = epochs remaining
#   x25 = sample index address (walks 0x000, 0x008, 0x010, 0x018)
#   x26 = samples remaining this epoch
# ============================================================
ADDI x24, x0, 150           # 150 epochs

epoch_loop:
ADDI x25, x0, 0             # first sample at 0x000
ADDI x26, x0, 4             # 4 samples

sample_loop:

# ------------------------------------------------------------
# 1. PREDICT:  pred_q = w_q . x     (accelerator, OP_DOT)
#
#    The weights are int64 (Q8); x is packed int8. They are different types, so
#    this uses LANE_64 with the weights unpacked - the accelerator dots 4
#    int64 weights against 4 int64 x values.
#
#    x is stored packed for compactness, so the program unpacks it into the
#    scratch area at 0x100 first.
# ------------------------------------------------------------

# ---- unpack x[sample] into 4 int64s at 0x100 ----
ADD  x5, x25, x0
LD   x6, 0(x5)              # the packed chunk

# lane 0
ANDI x7, x6, 255
SLLI x7, x7, 56             # sign-extend an int8: shift up then arithmetic down
SRAI x7, x7, 56
SD   x7, 256(x0)            # 0x100

# lane 1
SRLI x7, x6, 8
ANDI x7, x7, 255
SLLI x7, x7, 56
SRAI x7, x7, 56
SD   x7, 264(x0)

# lane 2
SRLI x7, x6, 16
ANDI x7, x7, 255
SLLI x7, x7, 56
SRAI x7, x7, 56
SD   x7, 272(x0)

# lane 3
SRLI x7, x6, 24
ANDI x7, x7, 255
SLLI x7, x7, 56
SRAI x7, x7, 56
SD   x7, 280(x0)

# ---- dot product: w_q (0x040) . x (0x100), 4 elements, LANE_64 ----
ADDI x5, x0, 2
SD   x5, 0(x10)             # clear

ADDI x3, x0, 64
SD   x3, 0(x16)             # ML_SRC_A = w_q
ADDI x3, x0, 256
SD   x3, 0(x17)             # ML_SRC_B = unpacked x

ADDI x3, x0, 4
SD   x3, 0(x18)             # ML_CNT = 4
SD   x3, 0(x15)             # ML_LEN = 4

ADDI x6, x0, 128            # dma
SD   x6, 0(x10)
tr_dma:
LD   x7, 0(x11)
ANDI x7, x7, 1
BNE  x7, x0, tr_dma

# start | signed | LANE_64 | OP_DOT = 0x01|0x04|0x18|0x20 = 0x3D = 61
ADDI x6, x0, 61
SD   x6, 0(x10)
tr_poll:
LD   x7, 0(x11)
ANDI x7, x7, 2
BEQ  x7, x0, tr_poll

LD   x8, 0(x14)             # x8 = pred_q  (Q8, NOT truncated)

# ------------------------------------------------------------
# 2. ERROR:  err_q = pred_q - (y << 8)
# ------------------------------------------------------------
SRLI x9, x25, 3             # sample index = addr / 8
SLLI x9, x9, 3
ADDI x9, x9, 32             # y is at 0x020 + index*8
LD   x9, 0(x9)              # x9 = y (plain integer)
SLLI x9, x9, 8              # y << 8  -> Q8
SUB  x8, x8, x9             # x8 = err_q

# ------------------------------------------------------------
# 3. UPDATE:  w_q[i] -= (err_q * x[i]) >> SHIFT     (SHIFT = 5)
#
#    x27 = weight index address (0x040 ..)
#    x28 = unpacked x address   (0x100 ..)
#    x29 = weights remaining
# ------------------------------------------------------------
ADDI x27, x0, 64            # w_q base
ADDI x28, x0, 256           # unpacked x base
ADDI x29, x0, 4

update_loop:
LD   x4, 0(x27)             # w_q[i]
LD   x5, 0(x28)             # x[i]

MUL  x6, x8, x5             # err_q * x[i]
SRAI x6, x6, 5              # >> SHIFT   (learning rate = 1/32)
SUB  x4, x4, x6             # w_q[i] -= gradient
SD   x4, 0(x27)

ADDI x27, x27, 8
ADDI x28, x28, 8
ADDI x29, x29, -1
BNE  x29, x0, update_loop

# ---- next sample ----
ADDI x25, x25, 8
ADDI x26, x26, -1
BNE  x26, x0, sample_loop

# ---- next epoch ----
ADDI x24, x24, -1
BNE  x24, x0, epoch_loop

# ============================================================
# Pack the learned weights (de-scaled from Q8) into one int8 chunk
# so the testbench can check every one.
#
#   w[i] = w_q[i] >> 8      (round-to-nearest via + 128 first)
# ============================================================
ADDI x27, x0, 64            # w_q base
ADDI x29, x0, 4
ADDI x30, x0, 0             # packed result
ADDI x31, x0, 0             # lane shift

pack_loop:
LD   x4, 0(x27)             # w_q[i]
ADDI x4, x4, 128            # round to nearest
SRAI x4, x4, 8              # de-scale from Q8
ANDI x5, x4, 255            # low byte
SLL  x5, x5, x31
OR   x30, x30, x5

ADDI x31, x31, 8
ADDI x27, x27, 8
ADDI x29, x29, -1
BNE  x29, x0, pack_loop

ADDI x6, x0, 96             # 0x060
SD   x30, 0(x6)             # store the packed learned weights

# ---- publish them so the test has a single observable value ----
ADDI x25, x0, 2040          # 0x7F8 out_port
SD   x30, 0(x25)

halt:
JAL  x0, halt
