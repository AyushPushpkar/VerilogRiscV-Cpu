import sys
import os

# TODO python tools/assembler.py program.asm program.mem

# --- ISA DEFINITIONS ---
OPCODES = {
    "LOAD":  0b0000011, "MATH":  0b0110011, "MOV":   0b0010011,
    "STORE": 0b0100011, "BEQ":   0b1100011, "JMP":   0b1101111,
    "M_EXT": 0b0001011
}

FUNCT = {
    "ADD": 0x0, "SUB": 0x1, "AND": 0x2, "OR":  0x3, "XOR": 0x4, "MOV": 0x5,
    "SLL": 0x6, "SRL": 0x7, "SRA": 0x8, "SLT": 0x9, "SLTU": 0xA,
    "MUL": 0x0, "DIV": 0x1, "REM": 0x2 
}

def parse_reg(reg_str):
    """Safely extracts integer from register string (e.g., 'R1' -> 1)"""
    try:
        return int(reg_str.upper().replace("R", "").strip())
    except ValueError:
        raise ValueError(f"Invalid register format: {reg_str}")

def assemble(input_file, output_file):
    with open(input_file, 'r') as f:
        lines = f.readlines()

    instructions = []
    labels = {}
    
    # ==========================================
    # PASS 1: Clean code & Map Labels
    # ==========================================
    current_address = 0
    for raw_line in lines:
        # Strip whitespace and comments
        line = raw_line.split("//")[0].strip()
        if not line:
            continue
            
        # Check if line is a label (e.g., "LOOP:")
        if line.endswith(":"):
            label_name = line[:-1]
            # PC increments by 4 (Byte Addressing)
            labels[label_name] = current_address 
        else:
            instructions.append(line)
            current_address += 4

    # ==========================================
    # PASS 2: Translate to Machine Code
    # ==========================================
    machine_code_output = []
    
    for line_num, line in enumerate(instructions):
        parts = line.replace(",", " ").split()
        inst_type = parts[0].upper()
        
        opcode = 0; funct = 0; rd = 0; rs1 = 0; rs2 = 0; imm = 0
        
        try:
            if inst_type in ["ADD", "SUB", "AND", "OR", "XOR", "MUL", "DIV", "REM"]:
                opcode = OPCODES["MATH"] if inst_type not in ["MUL", "DIV", "REM"] else OPCODES["M_EXT"]
                funct = FUNCT[inst_type]
                rd = parse_reg(parts[1])
                rs1 = parse_reg(parts[2])
                rs2 = parse_reg(parts[3])
                
            elif inst_type == "MOV":
                opcode = OPCODES["MOV"]
                funct = FUNCT["MOV"]
                rd = parse_reg(parts[1])
                imm = int(parts[2], 0)
                
            elif inst_type == "STORE":
                opcode = OPCODES["STORE"]
                rs2 = parse_reg(parts[1]) 
                rs1 = parse_reg(parts[2]) 
                
            elif inst_type == "LOAD":
                opcode = OPCODES["LOAD"]
                rd = parse_reg(parts[1])
                rs1 = parse_reg(parts[2])
                
            elif inst_type in ["JMP", "BEQ"]:
                opcode = OPCODES[inst_type]
                if inst_type == "BEQ":
                    rs1 = parse_reg(parts[1])
                    rs2 = parse_reg(parts[2])
                    target = parts[3]
                else:
                    target = parts[1]
                
                # Resolve Label or Raw Address
                if target in labels:
                    imm = labels[target]
                else:
                    imm = int(target, 0)
            else:
                raise ValueError(f"Unknown instruction: {inst_type}")

            # Mask immediate to strictly 8 bits to prevent overflow
            imm = imm & 0xFF

            # Bitwise pack the 32-bit instruction
            packed = (funct << 24) | (rs2 << 21) | (rs1 << 18) | (rd << 15) | (imm << 7) | opcode
            machine_code_output.append(f"{packed:08X}")
            
        except Exception as e:
            print(f"ERROR on instruction {line_num} ('{line}'): {e}")
            sys.exit(1)

    # ==========================================
    # OUTPUT GENERATION
    # ==========================================
    with open(output_file, 'w') as f:
        for hex_code in machine_code_output:
            f.write(hex_code + "\n")
            
    print(f"✅ Successfully assembled {len(machine_code_output)} instructions into '{output_file}'.")
    print("Labels detected:", labels)

if __name__ == "__main__":
    # Command Line Interface routing
    if len(sys.argv) != 3:
        print("Usage: python3 assembler.py <input.asm> <output.mem>")
        sys.exit(1)
        
    assemble(sys.argv[1], sys.argv[2])