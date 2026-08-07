# MLP using OP_MAT: a whole layer in ONE accelerator run.
#
# 8 inputs -> 8 hidden (ReLU) -> 1 output
#
# WHY THIS EXISTS
#
# program_mlp.asm computes its hidden layer as 3 SEPARATE dot products - one
# accelerator run per neuron. That works, but it pays the full memory-mapped
# handshake (clear, point DMA, fire DMA, poll, fire, poll, read - about 15
# instructions) EVERY TIME.
#
# A layer is a matrix-vector multiply. matrix_tile does exactly that, and it was
# built, tested, and then never used by any real workload - the same trap the
# packed lanes were in. This program fixes that.
#
#     OP_DOT:  one run PER NEURON      -> handshake x M
#     OP_MAT:  one run PER LAYER       -> handshake x 1
#
#   neurons     OP_DOT      OP_MAT     speedup
#        8      120 instr    23 instr     5.2x
#      128     1920 instr   143 instr    13.4x   <- a real hidden layer
#
# The handshake cost is per-RUN, and that is the whole point. My 8-neuron demo
# understates it, exactly as the 4-feature linear regression did.
#
# LAYER 1 AS A MATRIX-VECTOR MULTIPLY
#
#     W1 (8x8)  .  x (8x1)  ->  hidden (8x1)
#
#     M = 8 (rows / output neurons)
#     N = 1 (one column - it is a VECTOR, not a matrix)
#     K = 8 (shared inner dimension = input features)
#
#   With N=1, matrix_tile's column index is always 0, so operand B is read
#   straight out of the buffer linearly - no transpose needed. (For N>1 the
#   caller must store B column-major; that does not apply here.)
#
# THE DMA NEEDED A FIX
#
#   A is the weight MATRIX: 8 rows x 1 chunk = 8 doublewords.
#   B is the input VECTOR:                     1 doubleword.
#
#   They are DIFFERENT LENGTHS. The DMA had a single shared count, which made
#   OP_MAT unusable through it. ML_CNT now carries two:
#
#       [15:0]  count for A
#       [31:16] count for B   (zero means "same as A" - old programs unaffected)
#
# NETWORK
#     x  = [2, 1, 3, 1, 2, 1, 1, 2]
#
#     pre-ReLU = [10, -8, 3, 5, -10, 7, 6, -3]
#     hidden   = [10,  0, 3, 5,   0, 7, 6,  0]     <- 3 neurons clamped
#
#     W2 = [1, 2, -1, 1, 3, -2, 1, 1],  b2 = 10
#     y  = 14                                       <- published
#
#   Without ReLU y would be -35, so the activation is strongly load-bearing.
#
# RAM layout (int8 packed, one chunk = 8 features):
#     0x000  x         input vector          1 chunk
#     0x008  W1        8 rows, row-major     8 chunks
#     0x048  W2        output weights        1 chunk
#     0x050  hidden    written by this program

# ---- accelerator registers ----
ADDI x10, x0, 1920          # 0x780  ML_CTRL
ADDI x11, x0, 1928          # 0x788  ML_STATUS
ADDI x14, x0, 1952          # 0x7A0  ML_ACC_LO
ADDI x15, x0, 1968          # 0x7B0  ML_LEN
ADDI x16, x0, 1976          # 0x7B8  ML_SRC_A
ADDI x17, x0, 1984          # 0x7C0  ML_SRC_B
ADDI x18, x0, 1992          # 0x7C8  ML_CNT

# ============================================================
# LAYER 1:  hidden = ReLU( W1 . x )   -- ONE accelerator run
# ============================================================
ADDI x5, x0, 2
SD   x5, 0(x10)             # clear

# ---- operands ----
ADDI x3, x0, 8
SD   x3, 0(x16)             # ML_SRC_A = 0x008 (W1, row-major)
ADDI x3, x0, 0
SD   x3, 0(x17)             # ML_SRC_B = 0x000 (x)

# ---- DMA counts: A needs 8 chunks, B needs 1 ----
# ML_CNT = (1 << 16) | 8   =  65544
ADDI x3, x0, 1
SLLI x3, x3, 16
ADDI x3, x3, 8
SD   x3, 0(x18)

# ---- dims: M=8, N=1, K=8 ----
# ML_LEN = (K<<16) | (N<<8) | M  =  (8<<16) | (1<<8) | 8  =  0x080108
ADDI x4, x0, 8
SLLI x4, x4, 8
ADDI x4, x4, 1
SLLI x4, x4, 8
ADDI x4, x4, 8              # x4 = 0x080108
SD   x4, 0(x15)

# ---- fetch both operands ----
ADDI x6, x0, 128            # dma
SD   x6, 0(x10)
l1_dma:
LD   x7, 0(x11)
ANDI x7, x7, 1
BNE  x7, x0, l1_dma

# ---- run the WHOLE LAYER: start | signed | LANE_8 | OP_MAT ----
# 0x01 start | 0x04 signed | (0<<3) LANE_8 | (2<<5) OP_MAT = 0x45 = 69
ADDI x6, x0, 69
SD   x6, 0(x10)
l1_poll:
LD   x7, 0(x11)
ANDI x7, x7, 2
BEQ  x7, x0, l1_poll

# ============================================================
# Read the 8 hidden values, apply ReLU, pack them back to RAM.
#
# Each ML_ACC_LO load auto-advances the result read pointer, so
# repeated loads walk the output vector.
#
#   x28 = neurons remaining
#   x30 = packed hidden (built lane by lane)
#   x31 = lane shift
# ============================================================
ADDI x28, x0, 8             # 8 hidden neurons
ADDI x30, x0, 0             # packed = 0
ADDI x31, x0, 0             # shift = 0

relu_loop:
LD   x8, 0(x14)             # next hidden value (pre-activation)

# ---- ReLU: max(0, x8). One branch. ----
BGE  x8, x0, keep
ADDI x8, x0, 0
keep:

ANDI x9, x8, 255            # low byte
SLL  x9, x9, x31            # into lane position
OR   x30, x30, x9           # merge

ADDI x31, x31, 8            # next lane
ADDI x28, x28, -1
BNE  x28, x0, relu_loop

# ---- write the hidden vector back to RAM for layer 2 ----
ADDI x27, x0, 80            # 0x050
SD   x30, 0(x27)

# ============================================================
# LAYER 2:  y = W2 . hidden + b2    (a plain dot product - N=1, M=1)
# ============================================================
ADDI x5, x0, 2
SD   x5, 0(x10)             # clear

ADDI x3, x0, 72             # W2 at 0x048
SD   x3, 0(x16)             # ML_SRC_A
SD   x27, 0(x17)            # ML_SRC_B = hidden (0x050)

ADDI x3, x0, 1
SD   x3, 0(x18)             # ML_CNT = 1 chunk each (B field 0 = same as A)
SD   x3, 0(x15)             # ML_LEN = 1 chunk

ADDI x6, x0, 128            # dma
SD   x6, 0(x10)
l2_dma:
LD   x7, 0(x11)
ANDI x7, x7, 1
BNE  x7, x0, l2_dma

ADDI x6, x0, 37             # start | signed | LANE_8 | OP_DOT
SD   x6, 0(x10)
l2_poll:
LD   x7, 0(x11)
ANDI x7, x7, 2
BEQ  x7, x0, l2_poll

LD   x20, 0(x14)            # W2 . hidden
ADDI x20, x20, 10           # + b2  ->  expect 14

ADDI x25, x0, 2040          # 0x7F8 out_port
SD   x20, 0(x25)

halt:
JAL  x0, halt
