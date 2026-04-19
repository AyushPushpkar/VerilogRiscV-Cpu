# TODO python tools/assembler.py program.asm program.mem
    

#!/usr/bin/env python3
import sys

# ============================================================
# OPCODES (MATCHES YOUR defines.v)
# ============================================================

OPCODES = {
    "OP":       0b0110011,
    "OP_IMM":   0b0010011,
    "LOAD":     0b0000011,
    "STORE":    0b0100011,
    "BRANCH":   0b1100011,
    "JAL":      0b1101111,
    "JALR":     0b1100111,
    "LUI":      0b0110111,
    "AUIPC":    0b0010111,
}

# ============================================================
# FUNCT3
# ============================================================

FUNCT3 = {
    # Base ALU
    "ADD":  0b000,
    "SUB":  0b000,
    "SLL":  0b001,
    "SLT":  0b010,
    "SLTU": 0b011,
    "XOR":  0b100,
    "SRL":  0b101,
    "SRA":  0b101,
    "OR":   0b110,
    "AND":  0b111,

    # Immediate
    "ADDI": 0b000,
    "ANDI": 0b111,
    "ORI":  0b110,
    "XORI": 0b100,
    "SLTI": 0b010,

    # Memory
    "LW": 0b010,
    "SW": 0b010,

    # Branch
    "BEQ":  0b000,
    "BNE":  0b001,
    "BLT":  0b100,
    "BGE":  0b101,
    "BLTU": 0b110,
    "BGEU": 0b111,

    # M-extension
    "MUL":    0b000,
    "MULH":   0b001,
    "MULHSU": 0b010,
    "MULHU":  0b011,
    "DIV":    0b100,
    "DIVU":   0b101,
    "REM":    0b110,
    "REMU":   0b111,

    # B-extension subset
    "ANDN": 0b111,
    "ORN":  0b110,
    "XNOR": 0b100,
    "ROR":  0b101,
    "ROL":  0b001,
}

# ============================================================
# FUNCT7
# ============================================================

FUNCT7 = {
    # Base
    "ADD":  0x00,
    "SUB":  0x20,
    "SLL":  0x00,
    "SLT":  0x00,
    "SLTU": 0x00,
    "XOR":  0x00,
    "SRL":  0x00,
    "SRA":  0x20,
    "OR":   0x00,
    "AND":  0x00,

    # M-extension
    "MUL":    0x01,
    "MULH":   0x01,
    "MULHSU": 0x01,
    "MULHU":  0x01,
    "DIV":    0x01,
    "DIVU":   0x01,
    "REM":    0x01,
    "REMU":   0x01,

    # B-extension subset
    "ANDN": 0x20,
    "ORN":  0x20,
    "XNOR": 0x20,
    "ROR":  0x30,
    "ROL":  0x30,
}

# ============================================================
# HELPERS
# ============================================================

def reg(x):
    x = x.lower().replace("x", "").replace("r", "")
    v = int(x)
    if v < 0 or v > 31:
        raise ValueError("Register must be 0–31")
    return v

def imm(x):
    return int(x, 0)

# ============================================================
# ENCODERS
# ============================================================

def R(rd, rs1, rs2, f3, f7):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | OPCODES["OP"]

def I(rd, rs1, im, f3, opcode):
    im &= 0xFFF
    return (im << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | opcode

def S(rs1, rs2, im, f3):
    im &= 0xFFF
    return ((im >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((im & 0x1F) << 7) | OPCODES["STORE"]

def B(rs1, rs2, im, f3):
    im &= 0x1FFF
    return ((im >> 12) << 31) | (((im >> 5) & 0x3F) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (((im >> 1) & 0xF) << 8) | (((im >> 11) & 1) << 7) | OPCODES["BRANCH"]

def U(rd, im, opcode):
    return (im & 0xFFFFF000) | (rd << 7) | opcode

def J(rd, im):
    im &= 0x1FFFFF
    return ((im >> 20) << 31) | (((im >> 1) & 0x3FF) << 21) | (((im >> 11) & 1) << 20) | (((im >> 12) & 0xFF) << 12) | (rd << 7) | OPCODES["JAL"]

# ============================================================
# ASSEMBLER
# ============================================================

class Assembler:
    def __init__(self):
        self.labels = {}
        self.lines = []
        self.out = []

    def pass1(self, code):
        pc = 0
        for l in code:
            l = l.split("//")[0].strip()
            if not l:
                continue
            if l.endswith(":"):
                self.labels[l[:-1]] = pc
            else:
                self.lines.append(l)
                pc += 4

    def pass2(self):
        pc = 0

        for line in self.lines:
            p = line.replace(",", " ").split()
            op = p[0].upper()

            def target(x):
                return self.labels[x] if x in self.labels else imm(x)

            inst = 0

            # ================= R-TYPE =================
            if op in FUNCT7:
                rd, rs1, rs2 = reg(p[1]), reg(p[2]), reg(p[3])
                inst = R(rd, rs1, rs2, FUNCT3[op], FUNCT7[op])

            # ================= I-TYPE =================
            elif op in ["ADDI", "ANDI", "ORI", "XORI", "SLTI"]:
                rd, rs1, imv = reg(p[1]), reg(p[2]), imm(p[3])
                inst = I(rd, rs1, imv, FUNCT3[op], OPCODES["OP_IMM"])

            elif op == "LOAD":
                rd = reg(p[1])
                off, rs1r = p[2].split("(")
                rs1r = rs1r[:-1]
                inst = I(rd, reg(rs1r), imm(off), FUNCT3["LW"], OPCODES["LOAD"])

            elif op == "JALR":
                rd, rs1, imv = reg(p[1]), reg(p[2]), imm(p[3])
                inst = I(rd, rs1, imv, 0b000, OPCODES["JALR"])

            # ================= S-TYPE =================
            elif op == "STORE":
                rs2 = reg(p[1])
                off, rs1r = p[2].split("(")
                rs1r = rs1r[:-1]
                inst = S(reg(rs1r), rs2, imm(off), FUNCT3["SW"])

            # ================= B-TYPE =================
            elif op in ["BEQ", "BNE", "BLT", "BGE", "BLTU", "BGEU"]:
                rs1, rs2 = reg(p[1]), reg(p[2])
                offset = target(p[3]) - pc
                inst = B(rs1, rs2, offset, FUNCT3[op])

            # ================= J-TYPE =================
            elif op == "JAL":
                rd = reg(p[1])
                offset = target(p[2]) - pc
                inst = J(rd, offset)

            # ================= U-TYPE =================
            elif op in ["LUI", "AUIPC"]:
                rd, imv = reg(p[1]), imm(p[2])
                inst = U(rd, imv, OPCODES[op])

            else:
                raise Exception(f"Unknown instruction: {op}")

            self.out.append(f"{inst & 0xFFFFFFFF:08X}")
            pc += 4

    def assemble(self, infile, outfile):
        with open(infile) as f:
            code = f.readlines()

        self.pass1(code)
        self.pass2()

        with open(outfile, "w") as f:
            for line in self.out:
                f.write(line + "\n")

        print(f"✅ Assembled {len(self.out)} instructions")
        print(f"📍 Labels: {self.labels}")
        print(f"💾 Output → {outfile}")

# ============================================================
# MAIN
# ============================================================

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python3 assembler.py input.asm output.mem")
        sys.exit(1)

    Assembler().assemble(sys.argv[1], sys.argv[2])