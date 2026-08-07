//================================================================================
// Dot Product Unit - sequences MACs over a vector
//================================================================================
//
// Description:
//   Computes  y = sum(a[i] * b[i])  for i in [0, vec_len)
//
//   Phase 2 of the ML roadmap. This is control logic wrapped around vec_mac -
//   it does not reimplement multiply-accumulate.
//
//   vec_len counts CHUNKS (operand-bus words), not elements. At LANE_8 each
//   chunk carries 8 packed int8 elements, so a 64-element dot product is 8
//   chunks and takes 8 cycles. At LANE_64 a chunk is one element.
//
// Operand interface:
//   The unit streams operands. It drives `idx` and expects the corresponding
//   a[idx] / b[idx] to be presented on a_data / b_data in the same cycle.
//   This keeps the block agnostic to the operand source (scratchpad, memory,
//   register file, or MMIO buffer) - that choice is made at integration time.
//
// Protocol:
//   - assert `start` for one cycle with vec_len valid
//   - unit raises `busy`, streams vec_len chunks, one packed MAC per cycle
//   - `done` pulses for one cycle when the result is valid on `result`
//   - vec_len == 0 completes immediately with result = 0
//
// Notes (per docs/ML_ACCELERATOR_DESIGN.md):
//   - accumulator is wider than the operands
//   - signed / unsigned mode is selectable and latched at start
//
//================================================================================

`timescale 1ns/1ns

module dot_product #(
    parameter OP_WIDTH  = 64,
    parameter ACC_WIDTH = 128,
    parameter LEN_WIDTH = 16    // max vector length = 2^LEN_WIDTH - 1
)(
    input                        clk,
    input                        rst_n,

    // control
    input                        start,
    input                        is_signed,
    input      [1:0]             lane_mode,   // as vec_mac: 0=int8 .. 3=int64
    input      [LEN_WIDTH-1:0]   vec_len,     // CHUNKS, not elements - see below

    // Accumulate into the existing total instead of starting from zero.
    //
    // This is what makes SOFTWARE TILING work. A vector too big for the operand
    // buffer is processed in tiles: run the first with accumulate=0 and the rest
    // with accumulate=1, and the partial sums add up inside the 128-bit
    // accumulator - never rounded, never round-tripped through a 64-bit CPU
    // register.
    //
    // Without this, every start wiped the previous tile and tiling was
    // impossible.
    input                        accumulate,

    // streaming operand fetch
    output reg [LEN_WIDTH-1:0]   idx,
    input      [OP_WIDTH-1:0]    a_data,
    input      [OP_WIDTH-1:0]    b_data,

    // status / result
    output reg                   busy,
    output reg                   done,
    output     [ACC_WIDTH-1:0]   result
);

    localparam S_IDLE = 2'd0,
               S_RUN  = 2'd1,
               S_DONE = 2'd2;

    reg [1:0]           state;
    reg [LEN_WIDTH-1:0] len_q;        // latched length (in chunks)
    reg                 sign_q;       // latched signedness
    reg [1:0]           mode_q;       // latched lane mode

    // MAC control.
    //
    // These are COMBINATIONAL, deliberately. idx is a registered output and
    // a_data/b_data are driven combinationally from it, so the operands for
    // element `idx` are on the bus during the whole cycle we sit in S_RUN.
    // mac_en must be high during that same cycle - registering it would shift
    // the enable one cycle late, dropping element 0 and double-counting the
    // last one.
    wire mac_en = (state == S_RUN);

    // Zero the accumulator on start UNLESS software asked to accumulate, in
    // which case this tile's partial sum adds to what is already there.
    wire mac_clear = (state == S_IDLE) && start && !accumulate;

    // Last element is being consumed this cycle.
    wire last = (idx == len_q - 1'b1);

    //--------------------------------------------------------------------------
    // Datapath: vec_mac, NOT mac_unit.
    //
    // This block originally wrapped the scalar mac_unit, which meant OP_DOT was
    // stuck at one element per cycle no matter what lane mode software asked for
    // - the packed lanes were simply unreachable through the dot-product path.
    // Using vec_mac fixes that: at LANE_8, each chunk consumes 8 int8 elements
    // and the horizontal reduction sums them, so a 64-element dot product takes
    // 8 cycles instead of 64.
    //
    // Consequence: vec_len now counts CHUNKS (buffer entries), not elements.
    // Each chunk holds `lanes` elements, so a 64-element int8 vector is 8 chunks.
    // At LANE_64 a chunk is one element and the old semantics are unchanged.
    //--------------------------------------------------------------------------
    wire [ACC_WIDTH-1:0] lane_sum;

    vec_mac #(
        .DATA_WIDTH (OP_WIDTH),
        .ACC_WIDTH  (ACC_WIDTH)
    ) u_vec_mac (
        .clk       (clk),
        .rst_n     (rst_n),
        .clear     (mac_clear),
        .en        (mac_en),
        .is_signed (sign_q),
        .lane_mode (mode_q),
        .a         (a_data),
        .b         (b_data),
        .acc       (result),
        .lane_sum  (lane_sum)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state  <= S_IDLE;
            idx    <= {LEN_WIDTH{1'b0}};
            len_q  <= {LEN_WIDTH{1'b0}};
            sign_q <= 1'b0;
            mode_q <= 2'd0;
            busy   <= 1'b0;
            done   <= 1'b0;
        end
        else begin
            done <= 1'b0;   // default - pulsed for one cycle in S_DONE

            case (state)

                S_IDLE: begin
                    if (start) begin
                        len_q  <= vec_len;
                        sign_q <= is_signed;
                        mode_q <= lane_mode;
                        idx    <= {LEN_WIDTH{1'b0}};
                        busy   <= 1'b1;
                        // mac_clear is high combinationally this cycle, so the
                        // accumulator is zeroed on this same edge.
                        state  <= (vec_len == 0) ? S_DONE : S_RUN;
                    end
                end

                S_RUN: begin
                    // mac_en is high this cycle and a_data/b_data hold element
                    // `idx`, so the MAC consumes it on this edge. Advance idx
                    // on the same edge to line up the next element.
                    if (last)
                        state <= S_DONE;
                    else
                        idx <= idx + 1'b1;
                end

                S_DONE: begin
                    // The final MAC landed on the edge that brought us here,
                    // so `result` is valid now.
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
