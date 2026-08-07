# DMA-fed dot product.
#
# THE POINT: compare against program_ml.asm, which had to issue one SD per
# operand element. Here the operands already live in RAM, and the accelerator
# FETCHES THEM ITSELF - software just says "A is at address X, B is at Y, there
# are N of them, go."
#
# Filling the operand buffer drops from N stores to 3 register writes + 1 pulse,
# regardless of how big N is. That is the whole reason the DMA exists.
#
# Computes an 8-element dot product:
#
#   a = [1, 2, 3, 4, 5, 6, 7, 8]   at RAM 0x000
#   b = [2, 2, 2, 2, 2, 2, 2, 2]   at RAM 0x040
#
#   dot = 2 * (1+2+3+4+5+6+7+8) = 2 * 36 = 72
#
# Accelerator registers (ML_BASE = 0x780):
#   0x780  ML_CTRL    [0]=start [1]=clear [2]=signed [4:3]=lanes [6:5]=op [7]=dma
#   0x788  ML_STATUS  [0]=busy [1]=done
#   0x7A0  ML_ACC_LO  result
#   0x7B0  ML_LEN     vector length
#   0x7B8  ML_SRC_A   DMA source address of A
#   0x7C0  ML_SRC_B   DMA source address of B
#   0x7C8  ML_CNT     doublewords to fetch per operand

# ---- register addresses ----
ADDI x10, x0, 1920          # 0x780  ML_CTRL
ADDI x11, x0, 1928          # 0x788  ML_STATUS
ADDI x14, x0, 1952          # 0x7A0  ML_ACC_LO
ADDI x15, x0, 1968          # 0x7B0  ML_LEN
ADDI x16, x0, 1976          # 0x7B8  ML_SRC_A
ADDI x17, x0, 1984          # 0x7C0  ML_SRC_B
ADDI x18, x0, 1992          # 0x7C8  ML_CNT

# ============================================================
# Build the vectors in RAM.
#
# In a real program these would already be there - loaded from a file, produced
# by an earlier stage, or written once and reused across many operations. The
# stores here are SETUP, not per-operation cost: the DMA reads this same memory
# every time without software touching it again.
# ============================================================

# a = [1..8] at 0x000, one int64 per 8 bytes
ADDI x1, x0, 1
SD   x1, 0(x0)
ADDI x1, x0, 2
SD   x1, 8(x0)
ADDI x1, x0, 3
SD   x1, 16(x0)
ADDI x1, x0, 4
SD   x1, 24(x0)
ADDI x1, x0, 5
SD   x1, 32(x0)
ADDI x1, x0, 6
SD   x1, 40(x0)
ADDI x1, x0, 7
SD   x1, 48(x0)
ADDI x1, x0, 8
SD   x1, 56(x0)

# b = [2,2,2,2,2,2,2,2] at 0x040 (= 64)
ADDI x2, x0, 2
SD   x2, 64(x0)
SD   x2, 72(x0)
SD   x2, 80(x0)
SD   x2, 88(x0)
SD   x2, 96(x0)
SD   x2, 104(x0)
SD   x2, 112(x0)
SD   x2, 120(x0)

# ============================================================
# NOW THE ACCELERATOR RUN.
#
# Everything below is the per-operation cost. Note there is not a single store
# of operand DATA here - only addresses and counts.
# ============================================================

# ---- clear ----
ADDI x5, x0, 2
SD   x5, 0(x10)

# ---- tell the DMA where the operands are ----
ADDI x3, x0, 0              # A is at RAM 0x000
SD   x3, 0(x16)             # ML_SRC_A
ADDI x3, x0, 64             # B is at RAM 0x040
SD   x3, 0(x17)             # ML_SRC_B
ADDI x3, x0, 8              # 8 doublewords each
SD   x3, 0(x18)             # ML_CNT

# ---- fetch: ONE store pulls all 16 operands out of RAM ----
ADDI x6, x0, 128            # bit 7 = dma
SD   x6, 0(x10)

# ---- wait for the DMA to finish (busy is bit 0) ----
dma_wait:
LD   x7, 0(x11)             # ML_STATUS
ANDI x7, x7, 1              # busy?
BNE  x7, x0, dma_wait

# ---- vector length ----
ADDI x3, x0, 8
SD   x3, 0(x15)             # ML_LEN

# ---- run the dot product: op=DOT(1), signed, LANE_64(3) ----
# 0x01 start | 0x04 signed | (3<<3)=0x18 lanes | (1<<5)=0x20 op  =  0x3D = 61
ADDI x6, x0, 61
SD   x6, 0(x10)

# ---- poll until done (bit 1) ----
poll:
LD   x7, 0(x11)
ANDI x7, x7, 2
BEQ  x7, x0, poll

# ---- read the result ----
LD   x20, 0(x14)            # expect 72

# ---- publish ----
ADDI x25, x0, 2040          # 0x7F8 out_port
SD   x20, 0(x25)

halt:
JAL  x0, halt
