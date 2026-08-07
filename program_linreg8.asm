# 64-feature linear regression, int8 packed lanes.
#
# THE POINT. The 4-feature version (program_linreg.asm) proved the hardware
# works but showed no speedup - at 4 features the MMIO handshake costs about
# what the scalar math would.
#
# This is the workload that actually justifies the accelerator:
#
#     64 features, int8 packed, 8 per doubleword
#
#     scalar:       ~260 instructions  (LD, LD, MUL, ADD per feature)
#     accelerator:   ~25 instructions  (constant, regardless of feature count)
#
# And the packing pays twice:
#     storage:  64 bytes per vector instead of 512  (8x smaller)
#     DMA:      8 doublewords instead of 64          (8x fewer cycles)
#     compute:  8 chunks instead of 64               (8x fewer cycles)
#
# The model (w and x) is preloaded into RAM by the testbench, exactly as a real
# system would receive a trained model - it is not per-inference cost.
#
#     w = [(i%7)-3 for i in 0..63]    weights, range -3..3
#     x = [(i%5)+1 for i in 0..63]    features, range 1..5
#     b = 100                          bias
#
#     w.x = -15
#     y   = -15 + 100 = 85     <- published to out_port
#
# RAM layout (packed int8, 8 features per 8-byte doubleword):
#     0x000  w  = 8 doublewords = 64 features
#     0x040  x  = 8 doublewords = 64 features
#
# Accelerator registers (ML_BASE = 0x780):
#     0x780  ML_CTRL    [0]start [1]clear [2]signed [4:3]lanes [6:5]op [7]dma
#     0x788  ML_STATUS  [0]busy [1]done
#     0x7A0  ML_ACC_LO  result
#     0x7B0  ML_LEN     length in CHUNKS (not elements)
#     0x7B8  ML_SRC_A   DMA source A
#     0x7C0  ML_SRC_B   DMA source B
#     0x7C8  ML_CNT     doublewords to fetch per operand

# ---- register addresses ----
ADDI x10, x0, 1920          # 0x780  ML_CTRL
ADDI x11, x0, 1928          # 0x788  ML_STATUS
ADDI x14, x0, 1952          # 0x7A0  ML_ACC_LO
ADDI x15, x0, 1968          # 0x7B0  ML_LEN
ADDI x16, x0, 1976          # 0x7B8  ML_SRC_A
ADDI x17, x0, 1984          # 0x7C0  ML_SRC_B
ADDI x18, x0, 1992          # 0x7C8  ML_CNT

# ---- clear the accumulator and the buffer pointers ----
ADDI x5, x0, 2
SD   x5, 0(x10)

# ---- point the DMA at the packed vectors already in RAM ----
ADDI x3, x0, 0              # w at 0x000
SD   x3, 0(x16)             # ML_SRC_A
ADDI x3, x0, 64             # x at 0x040
SD   x3, 0(x17)             # ML_SRC_B

# ---- 8 doublewords each: 64 features / 8 per doubleword ----
ADDI x3, x0, 8
SD   x3, 0(x18)             # ML_CNT  = 8 doublewords
SD   x3, 0(x15)             # ML_LEN  = 8 CHUNKS

# ---- fetch: ONE store pulls 128 features (16 doublewords) out of RAM ----
ADDI x6, x0, 128            # bit 7 = dma
SD   x6, 0(x10)

dma_wait:
LD   x7, 0(x11)
ANDI x7, x7, 1              # busy?
BNE  x7, x0, dma_wait

# ---- run the dot product with PACKED int8 LANES ----
#
# op = DOT(1), signed, lane_mode = LANE_8 (0).
#   0x01 start | 0x04 signed | (0<<3) lanes | (1<<5) op  =  0x25 = 37
#
# Each of the 8 chunks does 8 int8 multiply-accumulates in ONE cycle, and the
# horizontal reduction sums the lanes. 64 features in 8 cycles.
ADDI x6, x0, 37
SD   x6, 0(x10)

poll:
LD   x7, 0(x11)
ANDI x7, x7, 2              # done?
BEQ  x7, x0, poll

# ---- y = w.x + b ----
LD   x20, 0(x14)            # ML_ACC_LO = w.x  (expect -15)
ADDI x20, x20, 100          # + bias           (expect 85)

# ---- publish ----
ADDI x25, x0, 2040          # 0x7F8 out_port
SD   x20, 0(x25)

halt:
JAL  x0, halt
