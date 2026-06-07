#!/usr/bin/env python3
import sys

# ============================================================
# OPCODES
# ============================================================

OPCODES = {
    "OP":         0b0110011,
    "OP_IMM":     0b0010011,
    "OP_32":      0b0111011,
    "OP_IMM_32":  0b0011011,
    "LOAD":       0b0000011,
    "STORE":      0b0100011,
    "BRANCH":     0b1100011,
    "JAL":        0b1101111,
    "JALR":       0b1100111,
    "LUI":        0b0110111,
    "AUIPC":      0b0010111,
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
    "ADDI":  0b000,
    "SLLI":  0b001,
    "SLTI":  0b010,
    "SLTIU": 0b011,
    "XORI":  0b100,
    "SRLI":  0b101,
    "SRAI":  0b101,
    "ORI":   0b110,
    "ANDI":  0b111,

    # RV64 word register-register
    "ADDW": 0b000,
    "SUBW": 0b000,
    "SLLW": 0b001,
    "SRLW": 0b101,
    "SRAW": 0b101,

    # RV64M word register-register
    "MULW":  0b000,
    "DIVW":  0b100,
    "DIVUW": 0b101,
    "REMW":  0b110,
    "REMUW": 0b111,

    # RV64 word immediate
    "ADDIW": 0b000,
    "SLLIW": 0b001,
    "SRLIW": 0b101,
    "SRAIW": 0b101,

    # Loads
    "LB":  0b000,
    "LH":  0b001,
    "LW":  0b010,
    "LD":  0b011,
    "LBU": 0b100,
    "LHU": 0b101,
    "LWU": 0b110,

    # Stores
    "SB": 0b000,
    "SH": 0b001,
    "SW": 0b010,
    "SD": 0b011,

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
    # Base R-type
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

    # RV64 word R-type
    "ADDW": 0x00,
    "SUBW": 0x20,
    "SLLW": 0x00,
    "SRLW": 0x00,
    "SRAW": 0x20,

    # M-extension (64-bit and 32-bit variants)
    "MUL":    0x01,
    "MULH":   0x01,
    "MULHSU": 0x01,
    "MULHU":  0x01,
    "DIV":    0x01,
    "DIVU":   0x01,
    "REM":    0x01,
    "REMU":   0x01,
    "MULW":   0x01,
    "DIVW":   0x01,
    "DIVUW":  0x01,
    "REMW":   0x01,
    "REMUW":  0x01,

    # B-extension subset
    "ANDN": 0x20,
    "ORN":  0x20,
    "XNOR": 0x20,
    "ROR":  0x30,
    "ROL":  0x30,
}

# ============================================================
# INSTRUCTION GROUPS
# ============================================================

R_TYPE = [
    "ADD", "SUB", "SLL", "SLT", "SLTU", "XOR", "SRL", "SRA", "OR", "AND",
    "MUL", "MULH", "MULHSU", "MULHU", "DIV", "DIVU", "REM", "REMU",
    "ANDN", "ORN", "XNOR", "ROR", "ROL",
]

R_TYPE_32 = [
    "ADDW", "SUBW", "SLLW", "SRLW", "SRAW",
    "MULW", "DIVW", "DIVUW", "REMW", "REMUW",
]

I_TYPE = [
    "ADDI", "ANDI", "ORI", "XORI", "SLTI", "SLTIU",
]

SHIFT_I_TYPE = [
    "SLLI", "SRLI", "SRAI",
]

I_TYPE_32 = [
    "ADDIW",
]

SHIFT_I_TYPE_32 = [
    "SLLIW", "SRLIW", "SRAIW",
]

LOAD_TYPE = [
    "LB", "LH", "LW", "LD", "LBU", "LHU", "LWU",
]

STORE_TYPE = [
    "SB", "SH", "SW", "SD",
]

BRANCH_TYPE = [
    "BEQ", "BNE", "BLT", "BGE", "BLTU", "BGEU",
]

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


def check_imm_range(value, bits, name):
    low = -(1 << (bits - 1))
    high = (1 << (bits - 1)) - 1
    if value < low or value > high:
        raise ValueError(f"{name} immediate {value} does not fit in signed {bits} bits")


def check_uimm_range(value, bits, name):
    low = 0
    high = (1 << bits) - 1
    if value < low or value > high:
        raise ValueError(f"{name} immediate {value} does not fit in unsigned {bits} bits")


def parse_mem_operand(x):
    # Example: 8(x1)
    off, rs1 = x.split("(")
    rs1 = rs1[:-1]
    return imm(off), reg(rs1)

# ============================================================
# ENCODERS
# ============================================================

def R(rd, rs1, rs2, f3, f7, opcode):
    return (
        (f7 << 25)
        | (rs2 << 20)
        | (rs1 << 15)
        | (f3 << 12)
        | (rd << 7)
        | opcode
    )


def I(rd, rs1, im, f3, opcode):
    check_imm_range(im, 12, "I-type")
    im &= 0xFFF
    return (
        (im << 20)
        | (rs1 << 15)
        | (f3 << 12)
        | (rd << 7)
        | opcode
    )


def SHIFT_I(rd, rs1, shamt, f3, f7, opcode, shamt_bits):
    check_uimm_range(shamt, shamt_bits, "shift")
    imm12 = (f7 << 5) | shamt
    return (
        (imm12 << 20)
        | (rs1 << 15)
        | (f3 << 12)
        | (rd << 7)
        | opcode
    )


def S(rs1, rs2, im, f3):
    check_imm_range(im, 12, "S-type")
    im &= 0xFFF
    return (
        ((im >> 5) << 25)
        | (rs2 << 20)
        | (rs1 << 15)
        | (f3 << 12)
        | ((im & 0x1F) << 7)
        | OPCODES["STORE"]
    )


def B(rs1, rs2, im, f3):
    check_imm_range(im, 13, "B-type")
    if im % 2 != 0:
        raise ValueError("Branch offset must be 2-byte aligned")

    im &= 0x1FFF
    return (
        ((im >> 12) << 31)
        | (((im >> 5) & 0x3F) << 25)
        | (rs2 << 20)
        | (rs1 << 15)
        | (f3 << 12)
        | (((im >> 1) & 0xF) << 8)
        | (((im >> 11) & 1) << 7)
        | OPCODES["BRANCH"]
    )


def U(rd, im, opcode):
    # Mask to 20 bits, then shift to [31:12]
    im &= 0xFFFFF
    return (
        (im << 12)
        | (rd << 7)
        | opcode
    )


def J(rd, im):
    check_imm_range(im, 21, "J-type")
    if im % 2 != 0:
        raise ValueError("JAL offset must be 2-byte aligned")

    im &= 0x1FFFFF
    return (
        ((im >> 20) << 31)
        | (((im >> 1) & 0x3FF) << 21)
        | (((im >> 11) & 1) << 20)
        | (((im >> 12) & 0xFF) << 12)
        | (rd << 7)
        | OPCODES["JAL"]
    )

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

        for line in code:
            line = line.split("//")[0].split("#")[0].strip()

            if not line:
                continue

            if line.endswith(":"):
                self.labels[line[:-1]] = pc
            else:
                self.lines.append(line)
                pc += 4

    def pass2(self):
        pc = 0

        for line in self.lines:
            p = line.replace(",", " ").split()
            op = p[0].upper()

            def target(x):
                return self.labels[x] if x in self.labels else imm(x)

            inst = 0

            # ================= R-TYPE 64-bit =================
            if op in R_TYPE:
                rd, rs1, rs2 = reg(p[1]), reg(p[2]), reg(p[3])
                inst = R(
                    rd,
                    rs1,
                    rs2,
                    FUNCT3[op],
                    FUNCT7[op],
                    OPCODES["OP"]
                )

            # ================= R-TYPE 32-bit WORD =================
            elif op in R_TYPE_32:
                rd, rs1, rs2 = reg(p[1]), reg(p[2]), reg(p[3])
                inst = R(
                    rd,
                    rs1,
                    rs2,
                    FUNCT3[op],
                    FUNCT7[op],
                    OPCODES["OP_32"]
                )

            # ================= I-TYPE 64-bit =================
            elif op in I_TYPE:
                rd, rs1, imv = reg(p[1]), reg(p[2]), imm(p[3])
                inst = I(
                    rd,
                    rs1,
                    imv,
                    FUNCT3[op],
                    OPCODES["OP_IMM"]
                )

            # ================= SHIFT I-TYPE 64-bit =================
            elif op in SHIFT_I_TYPE:
                rd, rs1, shamt = reg(p[1]), reg(p[2]), imm(p[3])

                if op == "SLLI":
                    f7 = 0x00
                elif op == "SRLI":
                    f7 = 0x00
                else:  # SRAI
                    f7 = 0x20

                inst = SHIFT_I(
                    rd,
                    rs1,
                    shamt,
                    FUNCT3[op],
                    f7,
                    OPCODES["OP_IMM"],
                    6
                )

            # ================= I-TYPE 32-bit WORD =================
            elif op in I_TYPE_32:
                rd, rs1, imv = reg(p[1]), reg(p[2]), imm(p[3])
                inst = I(
                    rd,
                    rs1,
                    imv,
                    FUNCT3[op],
                    OPCODES["OP_IMM_32"]
                )

            # ================= SHIFT I-TYPE 32-bit WORD =================
            elif op in SHIFT_I_TYPE_32:
                rd, rs1, shamt = reg(p[1]), reg(p[2]), imm(p[3])

                if op == "SLLIW":
                    f7 = 0x00
                elif op == "SRLIW":
                    f7 = 0x00
                else:  # SRAIW
                    f7 = 0x20

                inst = SHIFT_I(
                    rd,
                    rs1,
                    shamt,
                    FUNCT3[op],
                    f7,
                    OPCODES["OP_IMM_32"],
                    5
                )

            # ================= LOADS =================
            elif op in LOAD_TYPE:
                rd = reg(p[1])
                off, rs1 = parse_mem_operand(p[2])
                inst = I(
                    rd,
                    rs1,
                    off,
                    FUNCT3[op],
                    OPCODES["LOAD"]
                )

            # ================= STORES =================
            elif op in STORE_TYPE:
                rs2 = reg(p[1])
                off, rs1 = parse_mem_operand(p[2])
                inst = S(
                    rs1,
                    rs2,
                    off,
                    FUNCT3[op]
                )

            # ================= JALR =================
            elif op == "JALR":
                rd = reg(p[1])
                off, rs1 = parse_mem_operand(p[2])
                inst = I(
                    rd,
                    rs1,
                    off,
                    0b000,
                    OPCODES["JALR"]
                )

            # ================= BRANCHES =================
            elif op in BRANCH_TYPE:
                rs1, rs2 = reg(p[1]), reg(p[2])
                offset = target(p[3]) - pc
                inst = B(
                    rs1,
                    rs2,
                    offset,
                    FUNCT3[op]
                )

            # ================= JAL =================
            elif op == "JAL":
                rd = reg(p[1])
                offset = target(p[2]) - pc
                inst = J(rd, offset)

            # ================= U-TYPE =================
            elif op in ["LUI", "AUIPC"]:
                rd, imv = reg(p[1]), imm(p[2])
                inst = U(
                    rd,
                    imv,
                    OPCODES[op]
                )

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

        print(f"[OK] Assembled {len(self.out)} instructions")
        print(f"[labels] {self.labels}")
        print(f"[out] {outfile}")

# ============================================================
# MAIN
# ============================================================

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python3 assembler.py input.asm output.mem")
        sys.exit(1)

    Assembler().assemble(sys.argv[1], sys.argv[2])