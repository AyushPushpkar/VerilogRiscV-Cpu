//================================================================================
// Packed Vector MAC - lane-parallel multiply-accumulate with reduction
//================================================================================
//
// Description:
//   Treats the two 64-bit operands as PACKED VECTORS of narrow elements,
//   multiplies them lane-by-lane in parallel, horizontally sums all the lane
//   products, and accumulates that sum.
//
//       acc <- acc + sum( a[lane] * b[lane] )  for every lane
//
//   Phase 4-5 of the ML roadmap: packed lanes + horizontal reduction.
//
// Why this is the speedup:
//   mac_unit does ONE 64-bit multiply-accumulate per cycle. This block does
//   EIGHT int8 multiply-accumulates per cycle from the same 64-bit wires.
//   ML rarely needs 64-bit precision, so packing narrow elements buys
//   throughput for free.
//
// Lane modes (DATA_WIDTH = 64):
//   LANE_8  : 8 lanes x int8   -> 8 MACs/cycle
//   LANE_16 : 4 lanes x int16  -> 4 MACs/cycle
//   LANE_32 : 2 lanes x int32  -> 2 MACs/cycle
//   LANE_64 : 1 lane  x int64  -> 1 MAC/cycle  (equivalent to mac_unit)
//
// Precision rule (per docs/ML_ACCELERATOR_DESIGN.md):
//   Every lane product is widened to the full accumulator width BEFORE it
//   enters the reduction sum, and the accumulator is wider still. No lane
//   product and no partial sum is ever truncated.
//
//================================================================================

`timescale 1ns/1ns

module vec_mac #(
    parameter DATA_WIDTH = 64,    // packed operand width
    parameter ACC_WIDTH  = 128    // accumulator width
)(
    input                        clk,
    input                        rst_n,

    input                        clear,       // synchronous accumulator clear
    input                        en,          // accumulate this cycle
    input                        is_signed,   // 1 = signed lanes, 0 = unsigned
    input      [1:0]             lane_mode,   // see LANE_* below

    input      [DATA_WIDTH-1:0]  a,           // packed operand A
    input      [DATA_WIDTH-1:0]  b,           // packed operand B

    output reg [ACC_WIDTH-1:0]   acc,
    output     [ACC_WIDTH-1:0]   lane_sum     // this cycle's reduction (pre-acc)
);

    // Lane mode encoding
    localparam [1:0] LANE_8  = 2'd0,
                     LANE_16 = 2'd1,
                     LANE_32 = 2'd2,
                     LANE_64 = 2'd3;

    localparam N8  = DATA_WIDTH / 8;    // 8 lanes
    localparam N16 = DATA_WIDTH / 16;   // 4 lanes
    localparam N32 = DATA_WIDTH / 32;   // 2 lanes

    integer i;

    //--------------------------------------------------------------------------
    // Sign-extend a lane of arbitrary width up to ACC_WIDTH.
    //
    // Verilog has no generic "extend to N bits" operator, so this does it
    // explicitly: replicate the top bit (signed) or zero (unsigned) into all
    // the upper bits. Widening BEFORE the multiply would double the multiplier
    // cost, so instead each product is computed at its natural 2x lane width
    // and widened after - see the per-mode blocks below.
    //--------------------------------------------------------------------------

    //--------------------------------------------------------------------------
    // Per-mode lane products, each widened to ACC_WIDTH, then summed.
    //
    // All four modes are computed in parallel and lane_mode selects one. This
    // is area-cheap at these widths and keeps the logic flat and readable;
    // synthesis prunes whatever is unreachable when lane_mode is tied off.
    //--------------------------------------------------------------------------

    reg [ACC_WIDTH-1:0] sum8;
    reg [ACC_WIDTH-1:0] sum16;
    reg [ACC_WIDTH-1:0] sum32;
    reg [ACC_WIDTH-1:0] sum64;

    reg signed [15:0]  p8;      // int8  x int8  -> 16 bits
    reg signed [31:0]  p16;     // int16 x int16 -> 32 bits
    reg signed [63:0]  p32;     // int32 x int32 -> 64 bits
    reg signed [127:0] p64;     // int64 x int64 -> 128 bits

    reg signed [7:0]   a8,  b8;
    reg signed [15:0]  a16, b16;
    reg signed [31:0]  a32, b32;

    // ---- 8-bit lanes ----
    always @(*) begin
        sum8 = {ACC_WIDTH{1'b0}};
        for (i = 0; i < N8; i = i + 1) begin
            a8 = a[i*8 +: 8];
            b8 = b[i*8 +: 8];
            if (is_signed)
                p8 = $signed(a8) * $signed(b8);
            else
                p8 = $unsigned(a[i*8 +: 8]) * $unsigned(b[i*8 +: 8]);

            // Widen the 16-bit product to ACC_WIDTH, then add.
            if (is_signed)
                sum8 = sum8 + {{(ACC_WIDTH-16){p8[15]}}, p8};
            else
                sum8 = sum8 + {{(ACC_WIDTH-16){1'b0}},   p8};
        end
    end

    // ---- 16-bit lanes ----
    always @(*) begin
        sum16 = {ACC_WIDTH{1'b0}};
        for (i = 0; i < N16; i = i + 1) begin
            a16 = a[i*16 +: 16];
            b16 = b[i*16 +: 16];
            if (is_signed)
                p16 = $signed(a16) * $signed(b16);
            else
                p16 = $unsigned(a[i*16 +: 16]) * $unsigned(b[i*16 +: 16]);

            if (is_signed)
                sum16 = sum16 + {{(ACC_WIDTH-32){p16[31]}}, p16};
            else
                sum16 = sum16 + {{(ACC_WIDTH-32){1'b0}},    p16};
        end
    end

    // ---- 32-bit lanes ----
    always @(*) begin
        sum32 = {ACC_WIDTH{1'b0}};
        for (i = 0; i < N32; i = i + 1) begin
            a32 = a[i*32 +: 32];
            b32 = b[i*32 +: 32];
            if (is_signed)
                p32 = $signed(a32) * $signed(b32);
            else
                p32 = $unsigned(a[i*32 +: 32]) * $unsigned(b[i*32 +: 32]);

            if (is_signed)
                sum32 = sum32 + {{(ACC_WIDTH-64){p32[63]}}, p32};
            else
                sum32 = sum32 + {{(ACC_WIDTH-64){1'b0}},    p32};
        end
    end

    // ---- 64-bit (single lane; same behavior as mac_unit) ----
    always @(*) begin
        if (is_signed)
            p64 = $signed(a) * $signed(b);
        else
            p64 = $unsigned(a) * $unsigned(b);

        if (is_signed)
            sum64 = {{(ACC_WIDTH-128){p64[127]}}, p64};
        else
            sum64 = {{(ACC_WIDTH-128){1'b0}},     p64};
    end

    //--------------------------------------------------------------------------
    // Horizontal reduction output: pick the active mode's lane sum.
    //--------------------------------------------------------------------------
    assign lane_sum = (lane_mode == LANE_8)  ? sum8  :
                      (lane_mode == LANE_16) ? sum16 :
                      (lane_mode == LANE_32) ? sum32 :
                                               sum64;

    //--------------------------------------------------------------------------
    // Accumulate. clear takes priority over en, matching mac_unit.
    //--------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            acc <= {ACC_WIDTH{1'b0}};
        else if (clear)
            acc <= {ACC_WIDTH{1'b0}};
        else if (en)
            acc <= acc + lane_sum;
    end

endmodule
