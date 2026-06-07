
ADDI x1, x0, 10      # x1 = 10
ADDI x2, x0, 20      # x2 = 20

ADD  x3, x1, x2      # x3 = 30

STORE x3, 0(x0)      # MEM[0] = 30
LOAD  x4, 0(x0)      # x4 = 30