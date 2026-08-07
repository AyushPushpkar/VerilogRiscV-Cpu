`timescale 1ns/1ns
`include "defines.v"

//============================================================
// Load/store compliance test
//
// Checks data_memory.v against the RISC-V spec:
//
//   LB  / LH  / LW   sign-extend to XLEN
//   LBU / LHU / LWU  zero-extend to XLEN
//   LD               full 64 bits
//   SB / SH / SW / SD write exactly their width, no more
//
// The bug class: zero-extending where the spec says sign-extend
// (or vice versa). A value like 0xFF must load as -1 under LB
// but as +255 under LBU. Tests that only use small positive
// numbers never notice.
//
// Also checks misalignment flags, which the spec requires.
//============================================================

module tb_ldst_compliance;

    localparam XLEN = 64;

    reg         clk;
    reg         mem_read;
    reg         mem_write;
    reg  [2:0]  funct3;
    reg  [63:0] address;
    reg  [63:0] write_data;

    wire [63:0] read_data;
    wire        misaligned_access;
    wire        illegal_funct3;
    wire        addr_oob;

    integer checks, errors;

    data_memory #(
        .ADDR_WIDTH (8),
        .XLEN       (XLEN)
    ) dut (
        .clk               (clk),
        .mem_read          (mem_read),
        .mem_write         (mem_write),
        .funct3            (funct3),
        .address           (address),
        .write_data        (write_data),
        .read_data         (read_data),
        .misaligned_access (misaligned_access),
        .illegal_funct3    (illegal_funct3),
        .addr_oob          (addr_oob)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    //--------------------------------------------------------
    task do_store;
        input [2:0]  f3;
        input [63:0] addr;
        input [63:0] data;
        begin
            funct3     = f3;
            address    = addr;
            write_data = data;
            mem_write  = 1'b1;
            mem_read   = 1'b0;
            @(posedge clk);
            #1;
            mem_write  = 1'b0;
        end
    endtask

    task do_load;
        input  [2:0]  f3;
        input  [63:0] addr;
        output [63:0] data;
        begin
            funct3   = f3;
            address  = addr;
            mem_read = 1'b1;
            mem_write= 1'b0;
            #1;
            data     = read_data;
            mem_read = 1'b0;
        end
    endtask

    task expect_eq;
        input [511:0] name;
        input [63:0]  actual;
        input [63:0]  expect_val;
        begin
            checks = checks + 1;
            if (actual !== expect_val) begin
                errors = errors + 1;
                $display("FAIL [%0s] got=0x%016h expected=0x%016h",
                         name, actual, expect_val);
            end
            else
                $display("ok   [%0s] 0x%016h", name, actual);
        end
    endtask

    task expect_flag;
        input [511:0] name;
        input         actual;
        input         expect_val;
        begin
            checks = checks + 1;
            if (actual !== expect_val) begin
                errors = errors + 1;
                $display("FAIL [%0s] got=%0b expected=%0b",
                         name, actual, expect_val);
            end
            else
                $display("ok   [%0s] %0b", name, actual);
        end
    endtask

    reg [63:0] rv;

    initial begin
        checks    = 0;
        errors    = 0;
        mem_read  = 1'b0;
        mem_write = 1'b0;
        funct3    = 3'b000;
        address   = 64'd0;
        write_data= 64'd0;

        $display("================================================");
        $display("LOAD/STORE COMPLIANCE TEST");
        $display("================================================");

        @(posedge clk);
        #1;

        //----------------------------------------------------
        // Sign extension: the heart of the matter.
        // Store 0xFF at byte 0. LB must read -1; LBU must read +255.
        //----------------------------------------------------
        $display("-- byte sign vs zero extension --");

        do_store(`ST_SB, 64'd0, 64'h00000000_000000FF);

        do_load(`LD_LB, 64'd0, rv);
        expect_eq("LB  0xFF -> -1 (sign-extended)",
                  rv, 64'hFFFFFFFF_FFFFFFFF);

        do_load(`LD_LBU, 64'd0, rv);
        expect_eq("LBU 0xFF -> +255 (zero-extended)",
                  rv, 64'h00000000_000000FF);

        // 0x7F is positive under both.
        do_store(`ST_SB, 64'd1, 64'h0000007F);
        do_load (`LD_LB, 64'd1, rv);
        expect_eq("LB  0x7F -> +127", rv, 64'h0000007F);

        //----------------------------------------------------
        // Halfword
        //----------------------------------------------------
        $display("-- halfword sign vs zero extension --");

        do_store(`ST_SH, 64'd2, 64'h0000FFFF);

        do_load(`LD_LH, 64'd2, rv);
        expect_eq("LH  0xFFFF -> -1", rv, 64'hFFFFFFFF_FFFFFFFF);

        do_load(`LD_LHU, 64'd2, rv);
        expect_eq("LHU 0xFFFF -> +65535", rv, 64'h00000000_0000FFFF);

        do_store(`ST_SH, 64'd4, 64'h00008000);
        do_load (`LD_LH, 64'd4, rv);
        expect_eq("LH  0x8000 -> -32768", rv, 64'hFFFFFFFF_FFFF8000);

        //----------------------------------------------------
        // Word
        //----------------------------------------------------
        $display("-- word sign vs zero extension --");

        do_store(`ST_SW, 64'd8, 64'hFFFFFFFF);

        do_load(`LD_LW, 64'd8, rv);
        expect_eq("LW  0xFFFFFFFF -> -1", rv, 64'hFFFFFFFF_FFFFFFFF);

        do_load(`LD_LWU, 64'd8, rv);
        expect_eq("LWU 0xFFFFFFFF -> +4294967295",
                  rv, 64'h00000000_FFFFFFFF);

        do_store(`ST_SW, 64'd16, 64'h80000000);
        do_load (`LD_LW, 64'd16, rv);
        expect_eq("LW  0x80000000 -> INT32_MIN sign-extended",
                  rv, 64'hFFFFFFFF_80000000);

        //----------------------------------------------------
        // Doubleword round trip
        //----------------------------------------------------
        $display("-- doubleword --");

        do_store(`ST_SD, 64'd24, 64'hDEADBEEF_CAFEBABE);
        do_load (`LD_LD, 64'd24, rv);
        expect_eq("SD/LD round trip", rv, 64'hDEADBEEF_CAFEBABE);

        //----------------------------------------------------
        // Stores must not write beyond their width.
        // Zero 8 bytes, store one byte, check neighbors survive.
        //----------------------------------------------------
        $display("-- store width containment --");

        do_store(`ST_SD, 64'd32, 64'h00000000_00000000);
        do_store(`ST_SB, 64'd32, 64'h000000AA);
        do_load (`LD_LD, 64'd32, rv);
        expect_eq("SB writes 1 byte only", rv, 64'h00000000_000000AA);

        do_store(`ST_SD, 64'd40, 64'h00000000_00000000);
        do_store(`ST_SH, 64'd40, 64'h0000BBBB);
        do_load (`LD_LD, 64'd40, rv);
        expect_eq("SH writes 2 bytes only", rv, 64'h00000000_0000BBBB);

        do_store(`ST_SD, 64'd48, 64'h00000000_00000000);
        do_store(`ST_SW, 64'd48, 64'hCCCCCCCC);
        do_load (`LD_LD, 64'd48, rv);
        expect_eq("SW writes 4 bytes only", rv, 64'h00000000_CCCCCCCC);

        //----------------------------------------------------
        // Misalignment flags (spec requires detection)
        //----------------------------------------------------
        $display("-- misalignment detection --");

        funct3 = `LD_LD; address = 64'd1; mem_read = 1'b1; #1;
        expect_flag("LD @1 misaligned", misaligned_access, 1'b1);
        mem_read = 1'b0;

        funct3 = `LD_LD; address = 64'd8; mem_read = 1'b1; #1;
        expect_flag("LD @8 aligned", misaligned_access, 1'b0);
        mem_read = 1'b0;

        funct3 = `LD_LW; address = 64'd2; mem_read = 1'b1; #1;
        expect_flag("LW @2 misaligned", misaligned_access, 1'b1);
        mem_read = 1'b0;

        funct3 = `LD_LW; address = 64'd4; mem_read = 1'b1; #1;
        expect_flag("LW @4 aligned", misaligned_access, 1'b0);
        mem_read = 1'b0;

        funct3 = `LD_LH; address = 64'd3; mem_read = 1'b1; #1;
        expect_flag("LH @3 misaligned", misaligned_access, 1'b1);
        mem_read = 1'b0;

        funct3 = `LD_LB; address = 64'd7; mem_read = 1'b1; #1;
        expect_flag("LB @7 always aligned", misaligned_access, 1'b0);
        mem_read = 1'b0;

        //----------------------------------------------------
        $display("================================================");
        $display("CHECKS: %0d   ERRORS: %0d", checks, errors);
        if (errors == 0)
            $display("RESULT: LOAD/STORE MATCHES RISC-V SPEC");
        else
            $display("RESULT: LOAD/STORE DEVIATES FROM SPEC");
        $display("================================================");
        $finish;
    end

endmodule
