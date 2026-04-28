#TODO python tools/assembler.py program.asm program.mem

#!/usr/bin/env python3
import sys
from typing import List


# ============================================================
# OPCODES (MATCHES UPDATED defines.v)
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
    # R-type / OP-IMM base integer
    "ADD":   0b000,
    "SUB":   0b000,
    "SLL":   0b001,
    "SLT":   0b010,
    "SLTU":  0b011,
    "XOR":   0b100,
    "SRL":   0b101,
    "SRA":   0b101,
    "OR":    0b110,
    "AND":   0b111,

    "ADDI":  0b000,
    "SLLI":  0b001,
    "SLTI":  0b010,
    "SLTIU": 0b011,
    "XORI":  0b100,
    "SRLI":  0b101,
    "SRAI":  0b101,
    "ORI":   0b110,
    "ANDI":  0b111,

    # Loads
    "LB":    0b000,
    "LH":    0b001,
    "LW":    0b010,
    "LBU":   0b100,
    "LHU":   0b101,

    # Stores
    "SB":    0b000,
    "SH":    0b001,
    "SW":    0b010,

    # Branches
    "BEQ":   0b000,
    "BNE":   0b001,
    "BLT":   0b100,
    "BGE":   0b101,
    "BLTU":  0b110,
    "BGEU":  0b111,

    # RV32M
    "MUL":   0b000,
    "MULH":  0b001,
    "MULHSU":0b010,
    "MULHU": 0b011,
    "DIV":   0b100,
    "DIVU":  0b101,
    "REM":   0b110,
    "REMU":  0b111,
}


# ============================================================
# FUNCT7
# ============================================================

FUNCT7 = {
    # Base R-type
    "ADD":   0x00,
    "SUB":   0x20,
    "SLL":   0x00,
    "SLT":   0x00,
    "SLTU":  0x00,
    "XOR":   0x00,
    "SRL":   0x00,
    "SRA":   0x20,
    "OR":    0x00,
    "AND":   0x00,

    # Shift-immediates
    "SLLI":  0x00,
    "SRLI":  0x00,
    "SRAI":  0x20,

    # RV32M
    "MUL":   0x01,
    "MULH":  0x01,
    "MULHSU":0x01,
    "MULHU": 0x01,
    "DIV":   0x01,
    "DIVU":  0x01,
    "REM":   0x01,
    "REMU":  0x01,
}


R_TYPE_OPS = {
    "ADD", "SUB", "SLL", "SLT", "SLTU", "XOR", "SRL", "SRA", "OR", "AND",
    "MUL", "MULH", "MULHSU", "MULHU", "DIV", "DIVU", "REM", "REMU"
}

I_TYPE_OPS = {"ADDI", "SLTI", "SLTIU", "XORI", "ORI", "ANDI"}
SHIFT_IMM_OPS = {"SLLI", "SRLI", "SRAI"}
LOAD_OPS = {"LB", "LH", "LW", "LBU", "LHU", "LOAD"}
STORE_OPS = {"SB", "SH", "SW", "STORE"}
BRANCH_OPS = {"BEQ", "BNE", "BLT", "BGE", "BLTU", "BGEU"}
U_TYPE_OPS = {"LUI", "AUIPC"}


# ============================================================
# HELPERS
# ============================================================

def reg(x: str) -> int:
    x = x.strip().lower().replace("x", "").replace("r", "")
    v = int(x, 0)
    if v < 0 or v > 31:
        raise ValueError("Register must be 0-31")
    return v


def imm(x: str) -> int:
    return int(x, 0)


def signed_range_check(value: int, bits: int, context: str) -> None:
    lo = -(1 << (bits - 1))
    hi = (1 << (bits - 1)) - 1
    if not (lo <= value <= hi):
        raise ValueError(f"{context} immediate {value} out of signed {bits}-bit range [{lo}, {hi}]")


def unsigned_range_check(value: int, bits: int, context: str) -> None:
    lo = 0
    hi = (1 << bits) - 1
    if not (lo <= value <= hi):
        raise ValueError(f"{context} immediate {value} out of unsigned {bits}-bit range [{lo}, {hi}]")


def parse_mem_operand(text: str) -> tuple[int, int]:
    """
    Parses forms like:
      0(x1)
      -4(x2)
      0x10(x3)
    """
    if "(" not in text or not text.endswith(")"):
        raise ValueError(f"Invalid memory operand: {text}")
    off, base = text.split("(", 1)
    base = base[:-1]
    return imm(off), reg(base)


def strip_comment(line: str) -> str:
    # Support both '#' and '//' comments.
    line = line.split("#", 1)[0]
    line = line.split("//", 1)[0]
    return line.strip()


# ============================================================
# ENCODERS
# ============================================================

def R(rd: int, rs1: int, rs2: int, f3: int, f7: int) -> int:
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | OPCODES["OP"]


def I(rd: int, rs1: int, im: int, f3: int, opcode: int) -> int:
    im &= 0xFFF
    return (im << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | opcode


def I_SHIFT(rd: int, rs1: int, shamt: int, f3: int, f7: int) -> int:
    return (f7 << 25) | ((shamt & 0x1F) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | OPCODES["OP_IMM"]


def S(rs1: int, rs2: int, im: int, f3: int) -> int:
    im &= 0xFFF
    return ((im >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((im & 0x1F) << 7) | OPCODES["STORE"]


def B(rs1: int, rs2: int, im: int, f3: int) -> int:
    im &= 0x1FFF
    return (
        ((im >> 12) & 0x1) << 31 |
        ((im >> 5)  & 0x3F) << 25 |
        (rs2 << 20) |
        (rs1 << 15) |
        (f3 << 12) |
        ((im >> 1)  & 0xF) << 8 |
        ((im >> 11) & 0x1) << 7 |
        OPCODES["BRANCH"]
    )


def U(rd: int, im: int, opcode: int) -> int:
    return (im & 0xFFFFF000) | (rd << 7) | opcode


def J(rd: int, im: int) -> int:
    im &= 0x1FFFFF
    return (
        ((im >> 20) & 0x1) << 31 |
        ((im >> 1)  & 0x3FF) << 21 |
        ((im >> 11) & 0x1) << 20 |
        ((im >> 12) & 0xFF) << 12 |
        (rd << 7) |
        OPCODES["JAL"]
    )


# ============================================================
# ASSEMBLER
# ============================================================

class Assembler:
    def __init__(self) -> None:
        self.labels: dict[str, int] = {}
        self.lines: List[str] = []
        self.out: List[str] = []

    def pass1(self, code: List[str]) -> None:
        pc = 0
        for raw in code:
            line = strip_comment(raw)
            if not line:
                continue

            # Allow label-only lines and label+instruction lines.
            while ":" in line:
                label, rest = line.split(":", 1)
                label = label.strip()
                if not label:
                    raise ValueError("Empty label")
                if label in self.labels:
                    raise ValueError(f"Duplicate label: {label}")
                self.labels[label] = pc
                line = rest.strip()
                if not line:
                    break

            if line:
                self.lines.append(line)
                pc += 4

    def pass2(self) -> None:
        pc = 0

        for line in self.lines:
            parts = line.replace(",", " ").split()
            op = parts[0].upper()

            def target(x: str) -> int:
                return self.labels.get(x, imm(x))

            inst = 0

            # ------------------------------------------------------------
            # R-type
            # ------------------------------------------------------------
            if op in R_TYPE_OPS:
                if len(parts) != 4:
                    raise ValueError(f"{op} expects 3 operands")
                rd, rs1, rs2 = reg(parts[1]), reg(parts[2]), reg(parts[3])
                inst = R(rd, rs1, rs2, FUNCT3[op], FUNCT7[op])

            # ------------------------------------------------------------
            # I-type arithmetic/logical
            # ------------------------------------------------------------
            elif op in I_TYPE_OPS:
                if len(parts) != 4:
                    raise ValueError(f"{op} expects 3 operands")
                rd, rs1, imv = reg(parts[1]), reg(parts[2]), imm(parts[3])
                signed_range_check(imv, 12, op)
                inst = I(rd, rs1, imv, FUNCT3[op], OPCODES["OP_IMM"])

            # ------------------------------------------------------------
            # Shift-immediate
            # ------------------------------------------------------------
            elif op in SHIFT_IMM_OPS:
                if len(parts) != 4:
                    raise ValueError(f"{op} expects 3 operands")
                rd, rs1, shamt = reg(parts[1]), reg(parts[2]), imm(parts[3])
                unsigned_range_check(shamt, 5, op)
                inst = I_SHIFT(rd, rs1, shamt, FUNCT3[op], FUNCT7[op])

            # ------------------------------------------------------------
            # Loads
            # Supports both:
            #   LW x4, 0(x0)
            #   LOAD x4, 0(x0)   (legacy alias -> LW)
            # ------------------------------------------------------------
            elif op in LOAD_OPS:
                if len(parts) != 3:
                    raise ValueError(f"{op} expects 2 operands")
                rd = reg(parts[1])
                offset, rs1r = parse_mem_operand(parts[2])

                actual_op = "LW" if op == "LOAD" else op
                signed_range_check(offset, 12, actual_op)
                inst = I(rd, rs1r, offset, FUNCT3[actual_op], OPCODES["LOAD"])

            # ------------------------------------------------------------
            # JALR
            # Supports:
            #   JALR rd, rs1, imm
            #   JALR rd, imm(rs1)
            # ------------------------------------------------------------
            elif op == "JALR":
                if len(parts) == 4:
                    rd, rs1r, imv = reg(parts[1]), reg(parts[2]), imm(parts[3])
                elif len(parts) == 3:
                    rd = reg(parts[1])
                    imv, rs1r = parse_mem_operand(parts[2])
                else:
                    raise ValueError("JALR expects either 3 or 2 operands after mnemonic")
                signed_range_check(imv, 12, op)
                inst = I(rd, rs1r, imv, 0b000, OPCODES["JALR"])

            # ------------------------------------------------------------
            # Stores
            # Supports both:
            #   SW x3, 0(x0)
            #   STORE x3, 0(x0)  (legacy alias -> SW)
            # ------------------------------------------------------------
            elif op in STORE_OPS:
                if len(parts) != 3:
                    raise ValueError(f"{op} expects 2 operands")
                rs2 = reg(parts[1])
                offset, rs1r = parse_mem_operand(parts[2])

                actual_op = "SW" if op == "STORE" else op
                signed_range_check(offset, 12, actual_op)
                inst = S(rs1r, rs2, offset, FUNCT3[actual_op])

            # ------------------------------------------------------------
            # Branches
            # ------------------------------------------------------------
            elif op in BRANCH_OPS:
                if len(parts) != 4:
                    raise ValueError(f"{op} expects 3 operands")
                rs1r, rs2r = reg(parts[1]), reg(parts[2])
                offset = target(parts[3]) - pc
                if offset & 0x1:
                    raise ValueError(f"{op} branch target offset must be even, got {offset}")
                signed_range_check(offset, 13, op)
                inst = B(rs1r, rs2r, offset, FUNCT3[op])

            # ------------------------------------------------------------
            # JAL
            # ------------------------------------------------------------
            elif op == "JAL":
                if len(parts) != 3:
                    raise ValueError("JAL expects 2 operands")
                rd = reg(parts[1])
                offset = target(parts[2]) - pc
                if offset & 0x1:
                    raise ValueError(f"JAL target offset must be even, got {offset}")
                signed_range_check(offset, 21, op)
                inst = J(rd, offset)

            # ------------------------------------------------------------
            # U-type
            # ------------------------------------------------------------
            elif op in U_TYPE_OPS:
                if len(parts) != 3:
                    raise ValueError(f"{op} expects 2 operands")
                rd, imv = reg(parts[1]), imm(parts[2])
                inst = U(rd, imv, OPCODES[op])

            else:
                raise ValueError(f"Unknown instruction: {op}")

            self.out.append(f"{inst & 0xFFFFFFFF:08X}")
            pc += 4

    def assemble(self, infile: str, outfile: str) -> None:
        with open(infile, "r", encoding="utf-8") as f:
            code = f.readlines()

        self.pass1(code)
        self.pass2()

        with open(outfile, "w", encoding="utf-8") as f:
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