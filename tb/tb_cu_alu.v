//================================================================================
// Self-checking testbench: control_unit + alu cross-check
//================================================================================
// Drives real RV64 (opcode,funct3,funct7) encodings into the control unit,
// feeds the resulting alu_ctrl/funct7_out/is_word_op into the ALU, and compares
// the ALU result (and CU legality / control signals) against TB-computed
// expectations. Focuses on the risky paths:
//   - OP_OP_32 funct3=101 sharing (SRLW / SRAW / DIVUW)
//   - word M-ext ops (MULW/DIVW/DIVUW/REMW/REMUW)
//   - rotates (ROL/ROR) including rotate-by-0
//   - CU illegal-instruction decode for bad funct7
//================================================================================

`timescale 1ns/1ns
`include "defines.v"

module tb_cu_alu;

    // ---- CU I/O ----
    reg  [6:0] opcode;
    reg  [2:0] funct3;
    reg  [6:0] funct7;

    wire        reg_write, mem_read, mem_write, alu_src, jump, jalr, branch;
    wire [1:0]  alu_a_sel, wb_sel;
    wire [2:0]  alu_ctrl;
    wire [6:0]  funct7_out;
    wire        illegal_instr, is_word_op;

    // ---- ALU I/O ----
    reg  [63:0] A, B;
    wire [63:0] result;
    wire        zero, lt, ltu;

    integer errors = 0;
    integer checks = 0;

    control_unit cu (
        .opcode(opcode), .funct3(funct3), .funct7(funct7),
        .reg_write(reg_write), .mem_read(mem_read), .mem_write(mem_write),
        .alu_src(alu_src), .jump(jump), .jalr(jalr), .branch(branch),
        .alu_a_sel(alu_a_sel), .wb_sel(wb_sel), .alu_ctrl(alu_ctrl),
        .funct7_out(funct7_out), .illegal_instr(illegal_instr),
        .is_word_op(is_word_op)
    );

    alu #(.XLEN(64), .OP_WIDTH(3)) dut_alu (
        .A(A), .B(B),
        .funct3(alu_ctrl), .funct7(funct7_out), .is_word_op(is_word_op),
        .result(result), .zero(zero), .lt(lt), .ltu(ltu)
    );

    // Drive an R/word instruction and check ALU result + legality.
    task run_op;
        input [127:0] name;
        input [6:0]   op;
        input [2:0]   f3;
        input [6:0]   f7;
        input [63:0]  a_in;
        input [63:0]  b_in;
        input [63:0]  exp_result;
        input         exp_illegal;
        begin
            opcode = op; funct3 = f3; funct7 = f7;
            A = a_in; B = b_in;
            #1;
            checks = checks + 1;
            if (illegal_instr !== exp_illegal) begin
                errors = errors + 1;
                $display("FAIL [%0s]: illegal_instr=%b expected=%b (op=%b f3=%b f7=%b)",
                         name, illegal_instr, exp_illegal, op, f3, f7);
            end
            else if (!exp_illegal && (result !== exp_result)) begin
                errors = errors + 1;
                $display("FAIL [%0s]: result=%h expected=%h (a=%h b=%h)",
                         name, result, exp_result, a_in, b_in);
            end
            else begin
                $display("ok   [%0s] result=%h illegal=%b", name, result, illegal_instr);
            end
        end
    endtask

    // sign-extend a 32-bit value to 64
    function [63:0] sext32;
        input [31:0] v;
        sext32 = {{32{v[31]}}, v};
    endfunction

    initial begin
        //====================================================================
        // RV64I base R-type
        //====================================================================
        run_op("ADD",  `OP_OP, `FN_ADD_SUB, `F7_BASE,    64'd10, 64'd5,  64'd15, 1'b0);
        run_op("SUB",  `OP_OP, `FN_ADD_SUB, `F7_SUB_SRA, 64'd10, 64'd5,  64'd5,  1'b0);
        run_op("AND",  `OP_OP, `FN_AND,     `F7_BASE,     64'hF0, 64'h3C, 64'h30, 1'b0);
        run_op("OR",   `OP_OP, `FN_OR,      `F7_BASE,     64'hF0, 64'h0C, 64'hFC, 1'b0);
        run_op("XOR",  `OP_OP, `FN_XOR,     `F7_BASE,     64'hFF, 64'h0F, 64'hF0, 1'b0);
        run_op("SLL",  `OP_OP, `FN_SLL,     `F7_BASE,     64'h1,  64'd4,  64'h10, 1'b0);
        run_op("SRL",  `OP_OP, `FN_SRL_SRA, `F7_BASE,     64'h100,64'd4,  64'h10, 1'b0);
        run_op("SRA",  `OP_OP, `FN_SRL_SRA, `F7_SUB_SRA,
               64'hFFFFFFFFFFFFFF00, 64'd4, 64'hFFFFFFFFFFFFFFF0, 1'b0);

        //====================================================================
        // B-extension
        //====================================================================
        run_op("ANDN", `OP_OP, `FN_AND, `F7_ANDN, 64'hFF, 64'h0F, 64'hF0, 1'b0);
        run_op("ORN",  `OP_OP, `FN_OR,  `F7_ORN,  64'h0F, 64'hF0, 64'h0F | ~64'hF0, 1'b0);
        run_op("XNOR", `OP_OP, `FN_XOR, `F7_XNOR, 64'hFF, 64'h0F, ~(64'hFF ^ 64'h0F), 1'b0);
        run_op("ROL1", `OP_OP, `FN_SLL, `F7_ROT,  64'h1, 64'd4, 64'h10, 1'b0);
        run_op("ROR4", `OP_OP, `FN_SRL_SRA, `F7_ROT, 64'h10, 64'd4, 64'h1, 1'b0);
        // rotate-by-0 must return A unchanged (the A>>64 hazard)
        run_op("ROR0", `OP_OP, `FN_SRL_SRA, `F7_ROT,
               64'hDEADBEEF12345678, 64'd0, 64'hDEADBEEF12345678, 1'b0);
        run_op("ROL0", `OP_OP, `FN_SLL, `F7_ROT,
               64'hDEADBEEF12345678, 64'd0, 64'hDEADBEEF12345678, 1'b0);

        //====================================================================
        // RV64M full width
        //====================================================================
        run_op("MUL",  `OP_OP, `FN_MUL,  `F7_M_EXT, 64'd6, 64'd7, 64'd42, 1'b0);
        run_op("DIV",  `OP_OP, `FN_DIV,  `F7_M_EXT, 64'd20, 64'd6, 64'd3, 1'b0);
        run_op("DIVU", `OP_OP, `FN_DIVU, `F7_M_EXT, 64'd20, 64'd6, 64'd3, 1'b0);
        run_op("REM",  `OP_OP, `FN_REM,  `F7_M_EXT, 64'd20, 64'd6, 64'd2, 1'b0);
        run_op("REMU", `OP_OP, `FN_REMU, `F7_M_EXT, 64'd20, 64'd6, 64'd2, 1'b0);
        run_op("DIVby0", `OP_OP, `FN_DIV, `F7_M_EXT, 64'd5, 64'd0, {64{1'b1}}, 1'b0);

        //====================================================================
        // RV64 word ops (OP_OP_32) - the funct3=101 sharing path
        //====================================================================
        run_op("ADDW", `OP_OP_32, `FN_ADD_SUB, `F7_BASE,
               64'd1000000, 64'd1, sext32(32'd1000001), 1'b0);
        run_op("SUBW", `OP_OP_32, `FN_ADD_SUB, `F7_SUB_SRA,
               64'd5, 64'd9, sext32(-32'sd4), 1'b0);
        run_op("MULW", `OP_OP_32, `FN_MULW, `F7_M_EXT,
               64'd100000, 64'd3, sext32(32'd300000), 1'b0);
        run_op("SLLW", `OP_OP_32, `FN_SLL, `F7_BASE,
               64'h1, 64'd4, sext32(32'h10), 1'b0);

        // funct3 = 101 trio: must dispatch on funct7
        run_op("SRLW", `OP_OP_32, `FN_SRL_SRA, `F7_BASE,
               64'h0000000080000000, 64'd4, sext32(32'h08000000), 1'b0);
        run_op("SRAW", `OP_OP_32, `FN_SRL_SRA, `F7_SUB_SRA,
               64'hFFFFFFFF80000000, 64'd4, sext32(32'hF8000000), 1'b0);
        run_op("DIVUW",`OP_OP_32, `FN_SRL_SRA, `F7_M_EXT,
               64'd100, 64'd7, sext32(32'd14), 1'b0);

        run_op("DIVW", `OP_OP_32, `FN_DIVW, `F7_M_EXT,
               64'd100, 64'd7, sext32(32'd14), 1'b0);
        run_op("REMW", `OP_OP_32, `FN_REMW, `F7_M_EXT,
               64'd100, 64'd7, sext32(32'd2), 1'b0);
        run_op("REMUW",`OP_OP_32, `FN_REMUW, `F7_M_EXT,
               64'd100, 64'd7, sext32(32'd2), 1'b0);

        //====================================================================
        // CU legality: bad funct7 on word ops must be illegal
        //====================================================================
        // SLLW with funct7 != BASE  -> illegal
        run_op("SLLW_bad", `OP_OP_32, `FN_SLL, `F7_SUB_SRA, 0, 0, 0, 1'b1);
        // DIVW (f3=100) with funct7 != M_EXT -> illegal
        run_op("DIVW_bad", `OP_OP_32, `FN_DIVW, `F7_BASE, 0, 0, 0, 1'b1);
        // REMW (f3=110) with funct7 != M_EXT -> illegal
        run_op("REMW_bad", `OP_OP_32, `FN_REMW, `F7_SUB_SRA, 0, 0, 0, 1'b1);
        // REMUW (f3=111) with funct7 != M_EXT -> illegal
        run_op("REMUW_bad",`OP_OP_32, `FN_REMUW, `F7_BASE, 0, 0, 0, 1'b1);
        // SRLW/SRAW/DIVUW (f3=101) with a junk funct7 -> illegal
        run_op("W101_bad", `OP_OP_32, `FN_SRL_SRA, 7'b0010000, 0, 0, 0, 1'b1);

        //====================================================================
        // SUMMARY
        //====================================================================
        $display("================================================");
        $display("CHECKS: %0d   ERRORS: %0d", checks, errors);
        if (errors == 0) $display("RESULT: ALL TESTS PASSED");
        else             $display("RESULT: FAILURES DETECTED");
        $display("================================================");
        $finish;
    end

endmodule
