//================================================================================
// MAC Unit - Multiply-Accumulate primitive
//================================================================================
//
// Description:
//   Registered multiply-accumulate block:  acc <- acc + (a * b)
//
//   Phase 1 of the ML roadmap. This is the reusable primitive underneath
//   dot product, vector lane MAC, and matrix tile accumulation.
//
// Design rules (per docs/ML_ACCELERATOR_DESIGN.md):
//   - accumulator is wider than the inputs to absorb product growth
//   - clear and enable are separate controls
//   - signed / unsigned operand interpretation is selectable
//
// Notes:
//   - clear takes priority over enable
//   - a full-width product (2*OP_WIDTH) is sign/zero-extended into the
//     accumulator, so no product bits are lost before accumulation
//
//================================================================================

`timescale 1ns/1ns

module mac_unit #(
    parameter OP_WIDTH  = 64,   // operand width
    parameter ACC_WIDTH = 128   // accumulator width; must be >= 2*OP_WIDTH
)(
    input                        clk,
    input                        rst_n,

    input                        clear,      // synchronous accumulator clear
    input                        en,         // accumulate this cycle
    input                        is_signed,  // 1 = signed operands, 0 = unsigned

    input      [OP_WIDTH-1:0]    a,
    input      [OP_WIDTH-1:0]    b,

    output reg [ACC_WIDTH-1:0]   acc
);

    localparam PROD_WIDTH = 2*OP_WIDTH;

    // Full-width products. Both are computed; is_signed selects which one is
    // accumulated. Synthesis prunes the unused path when is_signed is tied off.
    wire signed [PROD_WIDTH-1:0] prod_s = $signed(a) * $signed(b);
    wire        [PROD_WIDTH-1:0] prod_u = a * b;

    // Widen the product to the accumulator width before adding, so the add is
    // done at full accumulator precision.
    wire [ACC_WIDTH-1:0] addend =
        is_signed ? {{(ACC_WIDTH-PROD_WIDTH){prod_s[PROD_WIDTH-1]}}, prod_s}
                  : {{(ACC_WIDTH-PROD_WIDTH){1'b0}},                 prod_u};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            acc <= {ACC_WIDTH{1'b0}};
        else if (clear)
            acc <= {ACC_WIDTH{1'b0}};
        else if (en)
            acc <= acc + addend;
    end

endmodule
