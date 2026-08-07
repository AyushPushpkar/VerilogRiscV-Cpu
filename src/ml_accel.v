//================================================================================
// ML Accelerator - memory-mapped front end for the ML datapath
//================================================================================
//
// Description:
//   Makes the ML blocks reachable from software. The CPU talks to this block
//   with ordinary load/store instructions to reserved addresses - no new
//   instructions and no ISA changes, as proposed in docs/ML_INTERFACE.md.
//
//   Three operating modes, selected by ML_CTRL[6:5]:
//
//     OP_MAC  single packed multiply-accumulate (drives vec_mac directly)
//     OP_DOT  full vector dot product           (drives dot_product)
//     OP_MAT  matrix multiply / GEMM            (drives matrix_tile)
//
// THE OPERAND BUFFER, AND WHY IT EXISTS
//
//   dot_product and matrix_tile STREAM their operands: they drive an index and
//   expect the corresponding data back in the SAME cycle, one element per clock.
//   The CPU cannot do that - it executes one instruction at a time, and a load
//   takes a whole instruction.
//
//   So the accelerator holds its own operand buffer. Software fills it first,
//   then starts the engine, which reads the buffer at full speed. The buffer is
//   written through ML_A / ML_B with an AUTO-INCREMENTING pointer: each write
//   appends one entry and advances. That costs a single register instead of one
//   address per buffer slot, which matters because reg_idx is only 3 bits wide
//   (8 slots total, and out_port owns one).
//
//   Writing to ML_CTRL with `clear` resets the fill pointer, so a new problem
//   starts from entry 0.
//
// Register map. reg_idx is the register NUMBER; cpu_top derives it from address
// bits [5:3], so the registers sit 8 bytes apart. That spacing is required:
// RISC-V permits SD/LD only at doubleword-aligned addresses.
//
//   idx 0  (0xC0)  ML_CTRL     W   control (bit layout below)
//   idx 1  (0xC8)  ML_STATUS   R   [0]=busy [1]=done
//   idx 2  (0xD0)  ML_A        W   operand A: direct value, or buffer append
//   idx 3  (0xD8)  ML_B        W   operand B: direct value, or buffer append
//   idx 4  (0xE0)  ML_ACC_LO   R   result, low  64 bits
//   idx 5  (0xE8)  ML_ACC_HI   R   result, high 64 bits
//   idx 6  (0xF0)  ML_LEN      W   vector length, or packed matrix dims
//
// ML_CTRL bit layout:
//   [0]     start      pulse: run the selected operation
//   [1]     clear      pulse: zero the accumulator and reset the fill pointer
//   [2]     is_signed  level: 1 = signed operands
//   [4:3]   lane_mode  level: 0=int8, 1=int16, 2=int32, 3=int64
//   [6:5]   op         level: 0=MAC, 1=DOT, 2=MAT
//
// ML_LEN layout:
//   OP_DOT :  [15:0]  vector length
//   OP_MAT :  [7:0] M, [15:8] N, [23:16] K
//
// Result reads (ML_ACC_LO / ML_ACC_HI):
//   OP_MAC / OP_DOT  the accumulator
//   OP_MAT           the LAST element emitted. matrix_tile streams C one
//                    element at a time; results are captured into the C buffer
//                    and can be read back by pointing the read pointer at them
//                    (see ML_STATUS / the c_buf note below).
//
//================================================================================

`timescale 1ns/1ns

module ml_accel #(
    parameter XLEN      = 64,
    parameter ACC_WIDTH = 128,
    parameter BUF_DEPTH = 64,    // operand buffer entries (per operand)
    parameter BUF_AW    = 6,     // $clog2(BUF_DEPTH)
    parameter MEM_AW    = 11     // data memory address width
)(
    input                    clk,
    input                    rst_n,

    // Memory-mapped access from the CPU.
    input                    sel,
    input                    we,          // 1 = store, 0 = load
    input      [3:0]         reg_idx,     // 16 register slots
    input      [XLEN-1:0]    wdata,

    output reg [XLEN-1:0]    rdata,

    //--------------------------------------------------------------------------
    // DMA read port into data memory.
    //
    // This is the whole point of the DMA: instead of software issuing one SD per
    // operand element, the accelerator fetches them itself, one doubleword per
    // cycle, straight out of RAM.
    //--------------------------------------------------------------------------
    output reg [MEM_AW-1:0]  dma_addr,
    input      [XLEN-1:0]    dma_rdata,

    //--------------------------------------------------------------------------
    // DMA WRITE port - result write-back.
    //
    // Without this, software reads results back one LD at a time. For an OP_MAT
    // output of M x N elements that is M*N loads, which becomes the bottleneck
    // once the DMA has removed the input-side one.
    //--------------------------------------------------------------------------
    output                   dma_we,
    output     [MEM_AW-1:0]  dma_waddr,
    output     [XLEN-1:0]    dma_wdata
);

    // Register offsets (16 slots, 8 bytes apart in the address space)
    localparam [3:0] ML_CTRL   = 4'd0,
                     ML_STATUS = 4'd1,
                     ML_A      = 4'd2,
                     ML_B      = 4'd3,
                     ML_ACC_LO = 4'd4,
                     ML_ACC_HI = 4'd5,
                     ML_LEN    = 4'd6,
                     ML_SRC_A  = 4'd7,   // DMA: byte address of A in RAM
                     ML_SRC_B  = 4'd8,   // DMA: byte address of B in RAM
                     ML_CNT    = 4'd9,   // DMA: doublewords to fetch per operand
                     ML_DST    = 4'd10;  // DMA-out: where to write results

    // Operation select (ML_CTRL[6:5])
    localparam [1:0] OP_MAC = 2'd0,
                     OP_DOT = 2'd1,
                     OP_MAT = 2'd2;

    //--------------------------------------------------------------------------
    // Control / configuration registers
    //--------------------------------------------------------------------------
    reg [XLEN-1:0] a_reg;        // direct operand A (OP_MAC)
    reg [XLEN-1:0] b_reg;        // direct operand B (OP_MAC)
    reg [XLEN-1:0] len_reg;      // length / dims

    reg            sign_reg;
    reg [1:0]      mode_reg;
    reg [1:0]      op_reg;

    reg              accum_reg;  // ML_CTRL[8]: accumulate across runs (tiling)

    // DMA configuration
    reg [MEM_AW-1:0] src_a_reg;  // byte address of A in RAM
    reg [MEM_AW-1:0] src_b_reg;  // byte address of B in RAM
    // DMA counts. A and B are SEPARATE, because they are not always the same
    // length: in a matrix-vector multiply, A is the weight matrix (M rows of
    // k_chunks) while B is a single vector (k_chunks). One shared count made
    // OP_MAT unusable through the DMA.
    //
    // ML_CNT layout:  [15:0] = count for A,  [31:16] = count for B
    //                 (if the B field is zero, B uses A's count - so the old
    //                  single-count behaviour still works for dot products)
    reg [BUF_AW:0]   cnt_a_reg;
    reg [BUF_AW:0]   cnt_b_reg;
    reg [MEM_AW-1:0] dst_reg;    // DMA-out destination address

    //--------------------------------------------------------------------------
    // Control-write decode. start/clear/dma are PULSES - high only on the cycle
    // the CPU's store lands, so one store means exactly one action.
    //--------------------------------------------------------------------------
    wire ctrl_write  = sel && we && (reg_idx == ML_CTRL);
    wire start_pulse = ctrl_write && wdata[0];
    wire clear_pulse = ctrl_write && wdata[1];
    wire dma_pulse   = ctrl_write && wdata[7];   // ML_CTRL[7] = fetch operands

    // ML_CTRL[9] = write results back to RAM at ML_DST, one doubleword per
    // cycle. Replaces M*N software loads with a single control write.
    wire dout_pulse  = ctrl_write && wdata[9];

    // ML_CTRL[8] = accumulate: add this run's result to the existing total
    // instead of starting from zero. This is what makes software tiling work -
    // a vector too big for the operand buffer is run as several tiles, and the
    // partial sums add up inside the 128-bit accumulator.
    wire accum_now   = ctrl_write ? wdata[8] : accum_reg;

    // Operand-buffer appends.
    wire a_write = sel && we && (reg_idx == ML_A);
    wire b_write = sel && we && (reg_idx == ML_B);

    //--------------------------------------------------------------------------
    // OPERAND BUFFERS
    //
    // Written by software (auto-incrementing), read by the streaming engines.
    //--------------------------------------------------------------------------
    reg [XLEN-1:0] buf_a [0:BUF_DEPTH-1];
    reg [XLEN-1:0] buf_b [0:BUF_DEPTH-1];

    reg [BUF_AW-1:0] fill_a;     // next write slot for A
    reg [BUF_AW-1:0] fill_b;     // next write slot for B

    //--------------------------------------------------------------------------
    // Engine selection.
    //
    // The op is taken from the WRITE DATA, not from op_reg. op_reg is registered
    // by this same control write, so on the cycle start_pulse is high it still
    // holds the PREVIOUS op - gating the engines on it would start the wrong one
    // (or none). The mode/sign the engines latch on start come from the same
    // write, so they are consistent.
    //
    // Third instance of this phase-alignment class of bug in this codebase: a
    // registered value must not gate a combinational pulse derived from the same
    // write.
    //--------------------------------------------------------------------------
    wire [1:0] op_now   = ctrl_write ? wdata[6:5] : op_reg;
    wire       sign_now = ctrl_write ? wdata[2]   : sign_reg;
    wire [1:0] mode_now = ctrl_write ? wdata[4:3] : mode_reg;

    wire dot_start = start_pulse && (op_now == OP_DOT);
    wire mat_start = start_pulse && (op_now == OP_MAT);
    wire mac_en    = start_pulse && (op_now == OP_MAC);

    //--------------------------------------------------------------------------
    // OP_MAC: vec_mac driven directly from a_reg / b_reg, one step per start.
    //--------------------------------------------------------------------------
    wire [ACC_WIDTH-1:0] mac_acc;
    wire [ACC_WIDTH-1:0] mac_lane_sum;

    vec_mac #(
        .DATA_WIDTH (XLEN),
        .ACC_WIDTH  (ACC_WIDTH)
    ) u_vec_mac (
        .clk       (clk),
        .rst_n     (rst_n),
        .clear     (clear_pulse),
        .en        (mac_en),
        .is_signed (sign_now),
        .lane_mode (mode_now),
        .a         (a_reg),
        .b         (b_reg),
        .acc       (mac_acc),
        .lane_sum  (mac_lane_sum)
    );

    //--------------------------------------------------------------------------
    // OP_DOT: dot_product streaming from the operand buffers.
    //--------------------------------------------------------------------------
    wire [15:0]          dot_idx;
    wire                 dot_busy;
    wire                 dot_done;
    wire [ACC_WIDTH-1:0] dot_result;

    // The engine drives dot_idx; present the buffered element combinationally.
    wire [XLEN-1:0] dot_a_data = buf_a[dot_idx[BUF_AW-1:0]];
    wire [XLEN-1:0] dot_b_data = buf_b[dot_idx[BUF_AW-1:0]];

    dot_product #(
        .OP_WIDTH  (XLEN),
        .ACC_WIDTH (ACC_WIDTH),
        .LEN_WIDTH (16)
    ) u_dot (
        .clk       (clk),
        .rst_n     (rst_n),
        .start      (dot_start),
        .is_signed  (sign_now),
        .lane_mode  (mode_now),
        .accumulate (accum_now),
        .vec_len    (len_reg[15:0]),
        .idx       (dot_idx),
        .a_data    (dot_a_data),
        .b_data    (dot_b_data),
        .busy      (dot_busy),
        .done      (dot_done),
        .result    (dot_result)
    );

    //--------------------------------------------------------------------------
    // OP_MAT: matrix_tile streaming from the operand buffers.
    //
    // A is row-major:      A[row][k] -> buf_a[row*K + k]
    // B is stored COLUMN-major so a column slice is contiguous:
    //                      B[k][col] -> buf_b[col*K + k]
    //
    // Storing B pre-transposed is what makes the column gather a simple index
    // instead of a scatter. matrix_tile deliberately leaves this to the caller.
    //--------------------------------------------------------------------------
    wire [7:0]           mat_row, mat_col, mat_k;
    wire                 mat_c_valid;
    wire [7:0]           mat_c_row, mat_c_col;
    wire [ACC_WIDTH-1:0] mat_c_data;
    wire                 mat_busy, mat_done;

    wire [7:0] dim_m = len_reg[7:0];
    wire [7:0] dim_n = len_reg[15:8];
    wire [7:0] dim_k = len_reg[23:16];

    // Lane count for the active mode - matrix_tile advances k by this much, and
    // the buffer index must scale the same way.
    reg [7:0] lanes;
    always @(*) begin
        case (mode_reg)
            2'd0:    lanes = XLEN / 8;
            2'd1:    lanes = XLEN / 16;
            2'd2:    lanes = XLEN / 32;
            default: lanes = XLEN / 64;
        endcase
    end

    // Chunks per row of A / column of B: ceil(K / lanes).
    wire [7:0] k_chunks = (dim_k + lanes - 8'd1) / lanes;

    // k_idx counts ELEMENTS; the buffer is indexed in CHUNKS.
    wire [7:0] k_chunk = (lanes == 0) ? 8'd0 : (mat_k / lanes);

    wire [BUF_AW-1:0] mat_a_idx = (mat_row * k_chunks) + k_chunk;
    wire [BUF_AW-1:0] mat_b_idx = (mat_col * k_chunks) + k_chunk;

    wire [XLEN-1:0] mat_a_data = buf_a[mat_a_idx];
    wire [XLEN-1:0] mat_b_data = buf_b[mat_b_idx];

    matrix_tile #(
        .DATA_WIDTH (XLEN),
        .ACC_WIDTH  (ACC_WIDTH),
        .DIM_WIDTH  (8)
    ) u_mat (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (mat_start),
        .is_signed (sign_now),
        .lane_mode (mode_now),
        .dim_m     (dim_m),
        .dim_n     (dim_n),
        .dim_k     (dim_k),
        .row       (mat_row),
        .col       (mat_col),
        .k_idx     (mat_k),
        .a_data    (mat_a_data),
        .b_data    (mat_b_data),
        .c_valid   (mat_c_valid),
        .c_row     (mat_c_row),
        .c_col     (mat_c_col),
        .c_data    (mat_c_data),
        .busy      (mat_busy),
        .done      (mat_done)
    );

    //--------------------------------------------------------------------------
    // RESULT CAPTURE
    //
    // matrix_tile streams C one element per pulse. Capture them into buf_a
    // (which is free once the engine has consumed it) so software can read them
    // back. Results land in row-major order at index (row*N + col).
    //
    // For OP_MAC / OP_DOT the result is a single accumulator value, held below.
    //--------------------------------------------------------------------------
    reg [ACC_WIDTH-1:0] result_q;   // last / final result, readable via ML_ACC

    // Read pointer for streaming C back out. Each ML_ACC_LO read advances it,
    // so software reads C[0], C[1], ... with repeated loads.
    reg [BUF_AW-1:0] read_ptr;

    reg [ACC_WIDTH-1:0] c_buf [0:BUF_DEPTH-1];

    wire [BUF_AW-1:0] c_wr_idx = (mat_c_row * dim_n) + mat_c_col;

    //--------------------------------------------------------------------------
    // DMA ENGINE
    //
    // Streams operands out of RAM into the buffers, one doubleword per cycle:
    //
    //     buf_a[i] <- MEM[src_a + 8*i]   for i in 0..cnt-1
    //     buf_b[i] <- MEM[src_b + 8*i]
    //
    // This replaces one CPU store per element with a single control write.
    // Filling a 64-entry buffer drops from 64 instructions to 4 (set src_a,
    // src_b, cnt, then pulse dma) - the accelerator does the rest itself.
    //
    // A and B are fetched in sequence rather than in parallel because there is
    // only one memory read port. Two ports would halve the latency; one keeps
    // data_memory simple, and the DMA is still ~1 element/cycle, which is far
    // faster than software can issue stores.
    //
    // dma_addr is REGISTERED and the memory read is asynchronous, so the data
    // for the address driven on cycle N arrives during cycle N. The write into
    // the buffer therefore happens one cycle behind the address - hence the
    // dma_wr_* pipeline registers below.
    //--------------------------------------------------------------------------
    localparam D_IDLE = 3'd0,
               D_LEAD = 3'd1,   // address driven; data valid next cycle
               D_A    = 3'd2,
               D_B    = 3'd3,
               D_OUT  = 3'd4;   // write results from c_buf back to RAM

    reg [2:0]        dma_state;
    reg [BUF_AW:0]   dma_i;        // element index within the current operand

    // Buffer-write controls, driven COMBINATIONALLY from the state.
    //
    // dma_addr is registered and dma_rdata is asynchronous, so dma_rdata already
    // holds the value for dma_addr during THIS cycle. Registering the write
    // enable (the first version) fired it one cycle late, by which point the
    // address had advanced - element 0 was dropped and everything shifted by one.
    //
    // Fourth instance of the same phase-alignment rule in this codebase: a
    // qualifier and the data it qualifies must be asserted in the same cycle.
    wire             dma_wr_en    = (dma_state == D_A) || (dma_state == D_B);
    wire             dma_wr_sel_b = (dma_state == D_B);
    wire [BUF_AW-1:0] dma_wr_idx  = dma_i[BUF_AW-1:0];

    wire dma_busy = (dma_state != D_IDLE);

    //--------------------------------------------------------------------------
    // DMA-OUT: write results from c_buf back to RAM.
    //
    // How many elements: for OP_MAT, M*N (the whole output matrix). For OP_DOT
    // and OP_MAC there is a single accumulator value, so one.
    //
    // The write port is driven COMBINATIONALLY from the state - dma_i indexes
    // c_buf, and the value must be on the bus during the same cycle dma_we is
    // high. Registering the enable would fire it a cycle after the index moved
    // on, which is the phase-alignment bug this codebase has now made four
    // times.
    //--------------------------------------------------------------------------
    wire [7:0] out_count = (op_reg == OP_MAT) ? (dim_m * dim_n) : 8'd1;

    assign dma_we    = (dma_state == D_OUT);
    assign dma_waddr = dst_reg + {dma_i[BUF_AW-1:0], 3'b000};   // dst + i*8
    assign dma_wdata = (op_reg == OP_MAT) ? c_buf[dma_i[BUF_AW-1:0]][XLEN-1:0]
                                          : result_q[XLEN-1:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dma_state    <= D_IDLE;
            dma_i        <= {(BUF_AW+1){1'b0}};
            dma_addr     <= {MEM_AW{1'b0}};
        end
        else begin
            case (dma_state)

                // TIMING, because this is easy to get wrong (and I did):
                //
                //   dma_addr  is REGISTERED - it appears on the bus one cycle
                //             after it is assigned.
                //   dma_rdata is ASYNCHRONOUS - it reflects whatever dma_addr
                //             holds during the CURRENT cycle.
                //   dma_wr_en is REGISTERED - the buffer write happens one cycle
                //             after it is asserted.
                //
                // So the write for address N must be scheduled while dma_addr
                // STILL holds N. Assert dma_wr_en and bump dma_addr on the same
                // edge, and the write lands exactly as dma_rdata's value for N is
                // captured. Advancing the address a cycle early (the first
                // version) drops element 0 and shifts everything by one.

                D_IDLE: begin
                    // Result write-back takes priority: it is only issued when
                    // an engine has already finished.
                    if (dout_pulse && (out_count != 0)) begin
                        dma_i     <= {(BUF_AW+1){1'b0}};
                        dma_state <= D_OUT;
                    end
                    else if (dma_pulse && (cnt_a_reg != 0)) begin
                        // Drive A's first address. dma_addr is registered, so it
                        // does not actually appear on the bus until next cycle -
                        // hence D_LEAD, which burns exactly that one cycle.
                        dma_addr  <= src_a_reg;
                        dma_i     <= {(BUF_AW+1){1'b0}};
                        dma_state <= D_LEAD;
                    end
                end

                // One cycle of lead-in: dma_addr now holds element 0 and
                // dma_rdata is valid for it. From here every cycle captures one
                // element.
                D_LEAD: dma_state <= D_A;

                D_A: begin
                    // dma_wr_en is high combinationally this cycle, and dma_rdata
                    // holds element dma_i. The write lands on this edge; advance
                    // the address on the same edge for the next one.
                    if (dma_i == cnt_a_reg - 1) begin
                        // Last A element is being captured this cycle. Point at
                        // B's first element for the next one.
                        dma_addr  <= src_b_reg;
                        dma_i     <= {(BUF_AW+1){1'b0}};
                        dma_state <= D_B;
                    end
                    else begin
                        dma_addr <= dma_addr + 8;   // next doubleword
                        dma_i    <= dma_i + 1'b1;
                    end
                end

                D_B: begin
                    if (dma_i == cnt_b_reg - 1)
                        dma_state <= D_IDLE;
                    else begin
                        dma_addr <= dma_addr + 8;
                        dma_i    <= dma_i + 1'b1;
                    end
                end

                // Write one result per cycle. dma_we/waddr/wdata are driven
                // combinationally above and are valid during THIS cycle, so the
                // write lands on this edge.
                D_OUT: begin
                    if (dma_i == out_count - 1)
                        dma_state <= D_IDLE;
                    else
                        dma_i <= dma_i + 1'b1;
                end

                default: dma_state <= D_IDLE;
            endcase
        end
    end

    //--------------------------------------------------------------------------
    // Status
    //--------------------------------------------------------------------------
    wire busy = dot_busy || mat_busy || dma_busy;
    reg  done_q;

    //--------------------------------------------------------------------------
    // Register writes / buffer fills
    //--------------------------------------------------------------------------
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_reg    <= {XLEN{1'b0}};
            b_reg    <= {XLEN{1'b0}};
            len_reg  <= {XLEN{1'b0}};
            sign_reg <= 1'b0;
            mode_reg <= 2'd0;
            op_reg    <= OP_MAC;
            accum_reg <= 1'b0;
            fill_a    <= {BUF_AW{1'b0}};
            fill_b    <= {BUF_AW{1'b0}};
            read_ptr  <= {BUF_AW{1'b0}};
            result_q  <= {ACC_WIDTH{1'b0}};
            done_q    <= 1'b0;
            src_a_reg <= {MEM_AW{1'b0}};
            src_b_reg <= {MEM_AW{1'b0}};
            cnt_a_reg <= {(BUF_AW+1){1'b0}};
            cnt_b_reg <= {(BUF_AW+1){1'b0}};
            dst_reg   <= {MEM_AW{1'b0}};
        end
        else begin
            //------------------------------------------------------------------
            // Control register
            //------------------------------------------------------------------
            if (ctrl_write) begin
                sign_reg  <= wdata[2];
                mode_reg  <= wdata[4:3];
                op_reg    <= wdata[6:5];
                accum_reg <= wdata[8];
            end

            // clear resets the accumulator (via vec_mac) AND the fill/read
            // pointers, so a new problem starts from entry 0.
            if (clear_pulse) begin
                fill_a   <= {BUF_AW{1'b0}};
                fill_b   <= {BUF_AW{1'b0}};
                read_ptr <= {BUF_AW{1'b0}};
                done_q   <= 1'b0;
            end

            //------------------------------------------------------------------
            // Operand writes.
            //
            // ML_A / ML_B always append to the buffer AND update the direct
            // register. OP_MAC uses the direct register; OP_DOT and OP_MAT read
            // the buffer. One write path serves both, so software does not have
            // to know which it is filling.
            //------------------------------------------------------------------
            if (a_write) begin
                a_reg          <= wdata;
                buf_a[fill_a]  <= wdata;
                fill_a         <= fill_a + 1'b1;
            end

            if (b_write) begin
                b_reg          <= wdata;
                buf_b[fill_b]  <= wdata;
                fill_b         <= fill_b + 1'b1;
            end

            //------------------------------------------------------------------
            // DMA buffer writes.
            //
            // One cycle behind the address the engine drove - dma_rdata now
            // holds the value for dma_wr_idx. Software writes and DMA writes
            // never collide: the CPU is stalled polling while the DMA runs.
            //------------------------------------------------------------------
            if (dma_wr_en) begin
                if (dma_wr_sel_b)
                    buf_b[dma_wr_idx] <= dma_rdata;
                else
                    buf_a[dma_wr_idx] <= dma_rdata;
            end

            //------------------------------------------------------------------
            // Configuration registers
            //------------------------------------------------------------------
            if (sel && we && (reg_idx == ML_LEN))
                len_reg <= wdata;

            if (sel && we && (reg_idx == ML_SRC_A))
                src_a_reg <= wdata[MEM_AW-1:0];

            if (sel && we && (reg_idx == ML_SRC_B))
                src_b_reg <= wdata[MEM_AW-1:0];

            if (sel && we && (reg_idx == ML_DST))
                dst_reg <= wdata[MEM_AW-1:0];

            if (sel && we && (reg_idx == ML_CNT)) begin
                cnt_a_reg <= wdata[BUF_AW:0];
                // A zero B-count means "same as A" - keeps every existing
                // program working unchanged.
                cnt_b_reg <= (wdata[16 +: (BUF_AW+1)] != 0)
                             ? wdata[16 +: (BUF_AW+1)]
                             : wdata[BUF_AW:0];
            end

            //------------------------------------------------------------------
            // Result capture
            //------------------------------------------------------------------
            if (mat_c_valid) begin
                c_buf[c_wr_idx] <= mat_c_data;
                result_q        <= mat_c_data;   // last element, for a quick read
            end

            if (dot_done)
                result_q <= dot_result;

            // OP_MAC result is the live accumulator; mirror it so ML_ACC reads
            // are uniform across all three modes.
            if (mac_en)
                result_q <= mac_acc;

            //------------------------------------------------------------------
            // done_q: set when an engine finishes, cleared on the next start.
            //------------------------------------------------------------------
            if (start_pulse)
                done_q <= 1'b0;
            else if (dot_done || mat_done)
                done_q <= 1'b1;

            //------------------------------------------------------------------
            // Reading ML_ACC_LO advances the C read pointer, so repeated loads
            // walk the result matrix. Harmless for OP_MAC / OP_DOT, which do not
            // use c_buf.
            //------------------------------------------------------------------
            if (sel && !we && (reg_idx == ML_ACC_LO) && (op_reg == OP_MAT))
                read_ptr <= read_ptr + 1'b1;
        end
    end

    //--------------------------------------------------------------------------
    // Register reads (combinational, matching the CPU's async load path).
    //
    // OP_MAC : the live accumulator (result is ready the cycle after start)
    // OP_DOT : result_q, latched when the engine finished
    // OP_MAT : c_buf walked by read_ptr
    //--------------------------------------------------------------------------
    wire [ACC_WIDTH-1:0] read_value =
        (op_reg == OP_MAT) ? c_buf[read_ptr] :
        (op_reg == OP_DOT) ? result_q        :
                             mac_acc;

    always @(*) begin
        rdata = {XLEN{1'b0}};

        if (sel && !we) begin
            case (reg_idx)
                ML_CTRL:   rdata = {{(XLEN-7){1'b0}}, op_reg, mode_reg,
                                    sign_reg, 2'b00};
                ML_STATUS: rdata = {{(XLEN-2){1'b0}}, done_q, busy};
                ML_A:      rdata = a_reg;
                ML_B:      rdata = b_reg;
                ML_ACC_LO: rdata = read_value[XLEN-1:0];
                ML_ACC_HI: rdata = read_value[ACC_WIDTH-1:XLEN];
                ML_LEN:    rdata = len_reg;
                ML_SRC_A:  rdata = {{(XLEN-MEM_AW){1'b0}},   src_a_reg};
                ML_SRC_B:  rdata = {{(XLEN-MEM_AW){1'b0}},   src_b_reg};
                ML_DST:    rdata = {{(XLEN-MEM_AW){1'b0}}, dst_reg};
                ML_CNT:    rdata = {{(XLEN-32){1'b0}},
                                    {(15-BUF_AW){1'b0}}, cnt_b_reg,
                                    {(15-BUF_AW){1'b0}}, cnt_a_reg};
                default:   rdata = {XLEN{1'b0}};
            endcase
        end
    end

endmodule
