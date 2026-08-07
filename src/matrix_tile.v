//================================================================================
// Matrix Tile Controller - GEMM via reused vector MACs
//================================================================================
//
// Description:
//   Computes  C = A x B  for  A[M x K] * B[K x N] -> C[M x N]
//
//   Phase 6 of the ML roadmap, and the last RTL block in
//   docs/ML_RTL_IMPLEMENTATION_ORDER.md.
//
// Core idea (per docs/ML_ACCELERATOR_DESIGN.md):
//   Matrix multiply is a dot product per output element:
//
//       C[i][j] = sum over k of ( A[i][k] * B[k][j] )
//
//   So this block is ORCHESTRATION, not arithmetic. It walks i, j, k with
//   three iterators and feeds vec_mac, which does the actual multiply-
//   accumulate. It does not reimplement a multiplier.
//
// Why vec_mac and not mac_unit:
//   Reusing vec_mac keeps the packed-lane throughput. At LANE_8 each
//   accumulate step consumes 8 int8 elements of the k dimension at once, so
//   a K=8 dot product is ONE cycle rather than eight.
//
//   The k iterator therefore advances by the lane count, not by 1. Callers
//   present a PACKED CHUNK of the k dimension on each step - see the operand
//   interface below.
//
// Operand interface (streaming, source-agnostic):
//   The block drives row / col / k_idx and expects the corresponding packed
//   chunks to be presented on a_data / b_data in the same cycle:
//
//       a_data = A[row][ k_idx .. k_idx + lanes-1 ]   (packed)
//       b_data = B[ k_idx .. k_idx+lanes-1 ][col]     (packed)
//
//   Note b_data is a COLUMN slice, so whoever supplies operands is
//   responsible for gathering it (or for storing B pre-transposed). Keeping
//   that outside this block is deliberate: it stays independent of whether
//   the matrices live in a scratchpad, RAM, or MMIO buffers.
//
// Result interface:
//   c_valid pulses for one cycle per output element, with c_row / c_col
//   identifying it and c_data holding the accumulated value. The consumer
//   writes it wherever C lives. No local C bank is needed - results are
//   streamed out as they complete.
//
// Protocol:
//   - assert start for one cycle with dim_m / dim_n / dim_k valid
//   - busy stays high while walking the output elements
//   - c_valid pulses once per element, in row-major order
//   - done pulses for one cycle after the last element
//   - any zero dimension completes immediately with no c_valid pulses
//
//================================================================================

`timescale 1ns/1ns

module matrix_tile #(
    parameter DATA_WIDTH = 64,     // packed operand width
    parameter ACC_WIDTH  = 128,    // accumulator width
    parameter DIM_WIDTH  = 8       // max matrix dimension = 2^DIM_WIDTH - 1
)(
    input                        clk,
    input                        rst_n,

    // control
    input                        start,
    input                        is_signed,
    input      [1:0]             lane_mode,   // as vec_mac: 0=int8 .. 3=int64
    input      [DIM_WIDTH-1:0]   dim_m,       // rows of A / rows of C
    input      [DIM_WIDTH-1:0]   dim_n,       // cols of B / cols of C
    input      [DIM_WIDTH-1:0]   dim_k,       // shared inner dimension

    // streaming operand fetch
    output reg [DIM_WIDTH-1:0]   row,         // i - current row of A
    output reg [DIM_WIDTH-1:0]   col,         // j - current col of B
    output reg [DIM_WIDTH-1:0]   k_idx,       // k - start of the packed chunk
    input      [DATA_WIDTH-1:0]  a_data,      // A[row][k_idx ..] packed
    input      [DATA_WIDTH-1:0]  b_data,      // B[.. k_idx][col] packed

    // result stream - one pulse per output element
    output                       c_valid,
    output     [DIM_WIDTH-1:0]   c_row,
    output     [DIM_WIDTH-1:0]   c_col,
    output     [ACC_WIDTH-1:0]   c_data,

    // status
    output reg                   busy,
    output reg                   done
);

    localparam S_IDLE = 2'd0,
               S_MAC  = 2'd1,   // accumulating one C element over k
               S_EMIT = 2'd2,   // that element is complete; publish it
               S_DONE = 2'd3;

    reg [1:0] state;

    // Latched configuration.
    reg [DIM_WIDTH-1:0] m_q, n_q, k_q;
    reg                 sign_q;
    reg [1:0]           mode_q;

    //--------------------------------------------------------------------------
    // How many k elements each accumulate step consumes.
    //
    // vec_mac packs the operands, so one step covers `lanes` elements of the k
    // dimension. This is why k_idx advances by lanes rather than by 1.
    //--------------------------------------------------------------------------
    reg [DIM_WIDTH-1:0] lanes;
    always @(*) begin
        case (mode_q)
            2'd0:    lanes = DATA_WIDTH / 8;    // int8  -> 8 lanes
            2'd1:    lanes = DATA_WIDTH / 16;   // int16 -> 4 lanes
            2'd2:    lanes = DATA_WIDTH / 32;   // int32 -> 2 lanes
            default: lanes = DATA_WIDTH / 64;   // int64 -> 1 lane
        endcase
    end

    // The k walk is done when the next chunk would start at or past k_q.
    wire k_last = ((k_idx + lanes) >= k_q);

    // After emitting an element, the next one normally sweeps k again. With
    // K=0 there is no k to sweep - every element is an empty sum (= 0) - so go
    // straight back to S_EMIT and publish the next zero.
    wire [1:0] next_after_emit = (k_q == 0) ? S_EMIT : S_MAC;

    // Output-element iteration bounds.
    wire col_last = (col == n_q - 1'b1);
    wire row_last = (row == m_q - 1'b1);

    //--------------------------------------------------------------------------
    // Datapath: the packed vector MAC. Same rationale as dot_product.v -
    // mac_en/mac_clear are COMBINATIONAL from the state so the enable is high
    // during exactly the cycle its operands sit on the bus. Registering them
    // would put the enable one cycle out of phase with the data.
    //--------------------------------------------------------------------------
    wire                 mac_en    = (state == S_MAC);
    wire                 mac_clear = ((state == S_IDLE) && start) ||
                                     (state == S_EMIT);
    wire [ACC_WIDTH-1:0] lane_sum;

    //--------------------------------------------------------------------------
    // Result stream.
    //
    // c_valid is COMBINATIONAL in S_EMIT, not registered - and that is the whole
    // point. c_data is wired straight to the accumulator, and mac_clear is also
    // high in S_EMIT, so the accumulator is zeroed on the edge LEAVING S_EMIT.
    // A registered c_valid would pulse one cycle later, publishing the value
    // after it had already been wiped: every result would read 0.
    //
    // Same phase-alignment rule as dot_product.v - a signal and the data it
    // qualifies must be asserted in the same cycle.
    //--------------------------------------------------------------------------
    assign c_valid = (state == S_EMIT);
    assign c_row   = row;
    assign c_col   = col;

    vec_mac #(
        .DATA_WIDTH (DATA_WIDTH),
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
        .acc       (c_data),
        .lane_sum  (lane_sum)
    );

    //--------------------------------------------------------------------------
    // Control FSM.
    //
    // Walks output elements in row-major order. For each, sweeps k, then emits.
    //--------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= S_IDLE;
            row     <= {DIM_WIDTH{1'b0}};
            col     <= {DIM_WIDTH{1'b0}};
            k_idx   <= {DIM_WIDTH{1'b0}};
            m_q     <= {DIM_WIDTH{1'b0}};
            n_q     <= {DIM_WIDTH{1'b0}};
            k_q     <= {DIM_WIDTH{1'b0}};
            sign_q  <= 1'b0;
            mode_q  <= 2'd0;
            busy    <= 1'b0;
            done    <= 1'b0;
        end
        else begin
            // Default - pulsed in S_DONE.
            done <= 1'b0;

            case (state)

                S_IDLE: begin
                    if (start) begin
                        m_q    <= dim_m;
                        n_q    <= dim_n;
                        k_q    <= dim_k;
                        sign_q <= is_signed;
                        mode_q <= lane_mode;

                        row    <= {DIM_WIDTH{1'b0}};
                        col    <= {DIM_WIDTH{1'b0}};
                        k_idx  <= {DIM_WIDTH{1'b0}};
                        busy   <= 1'b1;

                        // M=0 or N=0 means the OUTPUT matrix is empty - there
                        // are no elements to produce, so finish immediately.
                        //
                        // K=0 is different: C is still M x N, but every element
                        // is an empty sum, which is 0. Those zeros must still be
                        // emitted. Go straight to S_EMIT, skipping the k sweep -
                        // the accumulator was just cleared by mac_clear, so it
                        // already holds the right answer.
                        if (dim_m == 0 || dim_n == 0)
                            state <= S_DONE;
                        else if (dim_k == 0)
                            state <= S_EMIT;
                        else
                            state <= S_MAC;
                    end
                end

                // Accumulate one output element across the k dimension.
                // mac_en is high this cycle, so a_data/b_data for k_idx are
                // being consumed on this edge.
                S_MAC: begin
                    if (k_last)
                        state <= S_EMIT;
                    else
                        k_idx <= k_idx + lanes;
                end

                // The final MAC landed on the edge that brought us here, so
                // c_data is valid during this cycle - c_valid is asserted
                // combinationally above. mac_clear is also high now, zeroing the
                // accumulator on the edge out of here, ready for the next
                // element.
                S_EMIT: begin
                    k_idx <= {DIM_WIDTH{1'b0}};

                    if (col_last) begin
                        col <= {DIM_WIDTH{1'b0}};
                        if (row_last) begin
                            state <= S_DONE;
                        end
                        else begin
                            row   <= row + 1'b1;
                            state <= next_after_emit;
                        end
                    end
                    else begin
                        col   <= col + 1'b1;
                        state <= next_after_emit;
                    end
                end

                S_DONE: begin
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
