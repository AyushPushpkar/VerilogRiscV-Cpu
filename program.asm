// Initialize MMIO address (255) in R7
MOV R7 255

// Initialize LED pattern (170) in R1
MOV R1 170

// Inversion mask (255) in R2
MOV R2 255

LOOP:
    // Write pattern to MMIO
    STORE R1 R7
    
    // Invert the bits
    XOR R1 R1 R2
    
    // Loop infinitely
    JMP LOOP