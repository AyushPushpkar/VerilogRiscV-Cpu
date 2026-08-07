# 2-layer MLP (multi-layer perceptron) on the ML accelerator.
#
# Rung 3 of ML_POST_ROADMAP.md, and the first workload where the output of one
# accelerator run becomes the INPUT to the next.
#
#     4 inputs  ->  3 hidden (ReLU)  ->  1 output
#
#     hidden = ReLU(W1 . x)      layer 1: matrix-vector
#     y      = W2 . hidden + b2  layer 2: matrix-vector
#
# WHY THIS IS THE RIGHT NEXT STEP
#
# Each layer is a matrix-vector multiply, which is exactly what a neural network
# IS - the "deep learning" part is just doing this repeatedly. Every layer here
# is one dot product per output neuron.
#
# ACTIVATION: ReLU, not sigmoid.
#
#     ReLU(x) = max(0, x)
#
# On integer hardware that is a single branch - no lookup table, no floating
# point, nothing. This is why ReLU won: it is almost free. (Logistic regression
# needed a sigmoid LUT; an MLP does not.)
#
# THE NEW PART: feeding results back in.
#
# The hidden layer's 3 outputs must become layer 2's input vector. The program
# packs them back into RAM as int8 so the DMA can fetch them - the first time an
# accelerator result round-trips into another accelerator run.
#
# Network (integer weights):
#
#     W1 = [[ 1, -1,  2,  0],     x = [2, 1, 3, 1]
#           [-3, -1, -1,  0],
#           [ 1,  1, -1,  2]]
#
#     W1[0].x =   7  ->  ReLU ->  7
#     W1[1].x = -10  ->  ReLU ->  0    <- the activation actually FIRES
#     W1[2].x =   2  ->  ReLU ->  2
#
#     hidden = [7, 0, 2]
#
#     W2 = [2, -1, 3],  b2 = 5
#     y  = 2*7 + (-1)*0 + 3*2 + 5 = 25    <- published
#
#   Without ReLU the answer would be 35, so the activation is load-bearing -
#   a bug that skipped it would be caught.
#
# RAM layout (int8 packed, one chunk each; unused lanes are zero):
#     0x000  x         [2, 1, 3, 1, 0,0,0,0]
#     0x008  W1 row 0  [1,-1, 2, 0, 0,0,0,0]
#     0x010  W1 row 1  [-3,-1,-1,0, 0,0,0,0]
#     0x018  W1 row 2  [1, 1,-1, 2, 0,0,0,0]
#     0x020  W2        [2,-1, 3, 0, 0,0,0,0]
#     0x028  hidden    written by this program, then read back by the DMA
#
# Zero-padded lanes contribute 0*0 = 0 to the dot product, so a 4-element vector
# safely occupies an 8-lane chunk.

# ---- accelerator registers ----
ADDI x10, x0, 1920          # 0x780  ML_CTRL
ADDI x11, x0, 1928          # 0x788  ML_STATUS
ADDI x14, x0, 1952          # 0x7A0  ML_ACC_LO
ADDI x15, x0, 1968          # 0x7B0  ML_LEN
ADDI x16, x0, 1976          # 0x7B8  ML_SRC_A
ADDI x17, x0, 1984          # 0x7C0  ML_SRC_B
ADDI x18, x0, 1992          # 0x7C8  ML_CNT

# ---- fixed config: 1 chunk per operand (8 packed int8) ----
ADDI x3, x0, 1
SD   x3, 0(x18)             # ML_CNT = 1
SD   x3, 0(x15)             # ML_LEN = 1 chunk

# ---- x (the input) is always operand B ----
ADDI x3, x0, 0
SD   x3, 0(x17)             # ML_SRC_B = 0x000

# ============================================================
# LAYER 1: hidden[j] = ReLU(W1[j] . x)   for j = 0, 1, 2
#
#   x28 = address of the current W1 row (starts at 0x008)
#   x29 = neurons remaining
#   x30 = accumulated hidden vector, packed as int8 (built lane by lane)
#   x31 = shift amount for the next lane
# ============================================================
ADDI x28, x0, 8             # W1 row 0 at 0x008
ADDI x29, x0, 3             # 3 hidden neurons
ADDI x30, x0, 0             # packed hidden = 0
ADDI x31, x0, 0             # lane shift = 0

layer1:
# ---- clear ----
ADDI x5, x0, 2
SD   x5, 0(x10)

# ---- point operand A at this W1 row ----
SD   x28, 0(x16)            # ML_SRC_A = W1[j]

# ---- fetch ----
ADDI x6, x0, 128            # dma
SD   x6, 0(x10)
w1_dma:
LD   x7, 0(x11)
ANDI x7, x7, 1
BNE  x7, x0, w1_dma

# ---- dot product: LANE_8 packed, signed, OP_DOT ----
ADDI x6, x0, 37             # start|signed|LANE_8|OP_DOT
SD   x6, 0(x10)
w1_poll:
LD   x7, 0(x11)
ANDI x7, x7, 2
BEQ  x7, x0, w1_poll

LD   x8, 0(x14)             # x8 = W1[j] . x   (pre-activation)

# ============================================================
# ReLU: max(0, x8).  One branch. That is the entire activation.
# ============================================================
BGE  x8, x0, relu_done      # if x8 >= 0, keep it
ADDI x8, x0, 0              # else clamp to 0
relu_done:

# ---- pack this hidden value into lane j of x30 ----
ANDI x9, x8, 255            # keep the low byte (int8)
SLL  x9, x9, x31            # shift into lane position
OR   x30, x30, x9           # merge into the packed word

ADDI x31, x31, 8            # next lane is 8 bits up
ADDI x28, x28, 8            # next W1 row
ADDI x29, x29, -1
BNE  x29, x0, layer1

# ============================================================
# Write the packed hidden vector to RAM at 0x028, so the DMA can
# fetch it as layer 2's input.
#
# THIS IS THE NEW PART: an accelerator result becoming an
# accelerator operand.
# ============================================================
ADDI x27, x0, 40            # 0x028
SD   x30, 0(x27)

# ============================================================
# LAYER 2: y = W2 . hidden + b2
# ============================================================
ADDI x5, x0, 2
SD   x5, 0(x10)             # clear

ADDI x3, x0, 32             # W2 at 0x020
SD   x3, 0(x16)             # ML_SRC_A = W2
SD   x27, 0(x17)            # ML_SRC_B = hidden (0x028)

ADDI x6, x0, 128            # dma
SD   x6, 0(x10)
w2_dma:
LD   x7, 0(x11)
ANDI x7, x7, 1
BNE  x7, x0, w2_dma

ADDI x6, x0, 37             # dot product
SD   x6, 0(x10)
w2_poll:
LD   x7, 0(x11)
ANDI x7, x7, 2
BEQ  x7, x0, w2_poll

LD   x20, 0(x14)            # x20 = W2 . hidden
ADDI x20, x20, 5            # + b2 = 5   ->  expect 25

# ---- publish ----
ADDI x25, x0, 2040          # 0x7F8 out_port
SD   x20, 0(x25)

halt:
JAL  x0, halt
