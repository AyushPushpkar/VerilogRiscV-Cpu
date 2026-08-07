# ML accelerator demo: 16-element int8 dot product, run on the CPU.
#
# Drives the memory-mapped ML accelerator with ordinary SD/LD instructions.
# No custom instructions, no ISA changes.
#
# Vectors (int8):
#   a = [1,2,3,4,5,6,7,8, 1,2,3,4,5,6,7,8]
#   b = [1,2,3,4,5,6,7,8, 1,2,3,4,5,6,7,8]
#
#   dot(a,b) = 2 * (1+4+9+16+25+36+49+64)
#            = 2 * 204
#            = 408
#
# The accelerator packs 8 int8 lanes into each 64-bit operand, so 16 elements
# take 2 accumulate steps instead of 16. Result is published to out_port.
#
# Accelerator register map (cpu_top.v: ML_BASE = 0x780).
#
# Registers are 8 BYTES APART because RISC-V requires SD/LD to be doubleword
# aligned, and the packed operands are delivered with SD. A byte-spaced map
# would put ML_A at a misaligned address, which a conformant core must reject.
#
#   0x780  ML_CTRL    W   [0]=start [1]=clear [2]=signed [4:3]=lane_mode
#   0x790  ML_A       W   packed operand A
#   0x798  ML_B       W   packed operand B
#   0x7A0  ML_ACC_LO  R   accumulator, low 64 bits
#
# lane_mode 0 = int8 (8 lanes). So:
#   clear                     = 0x02
#   start, signed, int8 lanes = 0x05   ([0]=start, [2]=signed)

# ---- accelerator register addresses (all 8-byte aligned) ----
ADDI x10, x0, 1920           # x10 = 0x780  ML_CTRL
ADDI x12, x0, 1936           # x12 = 0x790  ML_A
ADDI x13, x0, 1944           # x13 = 0x798  ML_B
ADDI x14, x0, 1952           # x14 = 0x7A0  ML_ACC_LO

# ---- build the packed operand 0x0807060504030201 = [1,2,3,4,5,6,7,8] ----
# Lane 0 is the LOW byte, so byte i holds element i+1.
# Built one byte at a time: shift left 8, OR in the next byte.
ADDI x1, x0, 8              # x1 = 0x08
SLLI x1, x1, 8
ADDI x1, x1, 7              # x1 = 0x0807
SLLI x1, x1, 8
ADDI x1, x1, 6              # x1 = 0x080706
SLLI x1, x1, 8
ADDI x1, x1, 5              # x1 = 0x08070605
SLLI x1, x1, 8
ADDI x1, x1, 4              # x1 = 0x0807060504
SLLI x1, x1, 8
ADDI x1, x1, 3              # x1 = 0x080706050403
SLLI x1, x1, 8
ADDI x1, x1, 2              # x1 = 0x08070605040302
SLLI x1, x1, 8
ADDI x1, x1, 1              # x1 = 0x0807060504030201

# ---- clear the accumulator ----
ADDI x5, x0, 2              # 0x02 = clear
SD   x5, 0(x10)             # ML_CTRL <- clear

# ---- control word: start | signed | int8 lanes ----
ADDI x6, x0, 5              # 0x05 = start(bit0) | signed(bit2)

# ---- chunk 1: elements 0..7 ----
SD   x1, 0(x12)             # ML_A <- [1..8]
SD   x1, 0(x13)             # ML_B <- [1..8]
SD   x6, 0(x10)             # ML_CTRL <- start   (8 MACs in one cycle)

# ---- chunk 2: elements 8..15 (same vectors again) ----
SD   x1, 0(x12)             # ML_A <- [1..8]
SD   x1, 0(x13)             # ML_B <- [1..8]
SD   x6, 0(x10)             # ML_CTRL <- start   (8 more MACs)

# ---- read the result and publish it ----
LD   x7, 0(x14)             # x7 = ML_ACC_LO  (expect 408)

ADDI x11, x0, 2040           # x11 = 0x7F8, MMIO output port (8-byte aligned)
SD   x7, 0(x11)             # out_port <- 408

# ---- halt ----
halt:
JAL  x0, halt
