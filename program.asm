# Basic CPU smoke test.
#
# Computes 10 + 20, round-trips it through memory, publishes it to the MMIO
# output port, then halts.
#
# MMIO: address 0x7F8 is the output port (MMIO_ADDRESS in cpu_top.v). It is
# 8-byte aligned because RISC-V only permits SD at doubleword-aligned addresses.

ADDI x1, x0, 10         # x1 = 10
ADDI x2, x0, 20         # x2 = 20

ADD  x3, x1, x2         # x3 = 30

SD   x3, 0(x0)          # MEM[0] = 30
LD   x4, 0(x0)          # x4 = 30  (must read back what we stored)

ADDI x5, x0, 2040        # x5 = 0x7F8, the MMIO output port (8-byte aligned)
SD   x4, 0(x5)          # out_port = 30

# Halt: park the PC on itself. Without this the PC walks off the end of the
# program into zeroed ROM, which decodes as an illegal instruction and looks
# like a CPU fault when it is really just the program running out.
halt:
JAL  x0, halt
