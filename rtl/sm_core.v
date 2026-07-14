// ============================================================================
// AURORA SM (streaming multiprocessor)
// 3-stage warp pipeline: ISSUE (sched+fetch) -> EX (RF read + SIMD) -> WB.
// - WARPS resident warps, LANES-wide SIMD, per-warp PC + active mask
// - shared memory (SMEM_KB), banked flop array with SRAM hook
// - global LD/ST via lsu request bus (coalesced per warp, serviced per lane
//   by the chiplet L2 slice -- one lane per cycle, warp stalls until done)
// - SETP folds into the active mask; BRA is uniform (any-active taken)
// - BAR: warp waits until all launched warps reach the barrier
// ============================================================================
`include "aurora_pkg.vh"

module sm_core #(
    parameter SM_ID   = 0,
    parameter CHIP_ID = 0
)(
    input  wire                     clk,
    input  wire                     rst,
    // kernel launch: host writes imem then pulses launch with warp count
    input  wire                     launch,
    input  wire [`WARP_ID_W:0]      launch_nwarps,
    input  wire                     imem_we,
    input  wire [9:0]               imem_waddr,
    input  wire [31:0]              imem_wdata,
    output wire                     sm_idle,       // all warps exited
    // global memory port (to L2 slice), one request at a time
    output reg                      gmem_req,
    output reg                      gmem_we,
    output reg  [31:0]              gmem_addr,
    output reg  [31:0]              gmem_wdata,
    input  wire                     gmem_ack,
    input  wire [31:0]              gmem_rdata
);
    // ---------------- warp state ----------------
    reg  [`WARPS-1:0]  w_launched, w_exited, w_atbar;
    reg  [9:0]         w_pc   [0:`WARPS-1];
    reg  [`LANES-1:0]  w_mask [0:`WARPS-1];
    reg  [`WARPS-1:0]  w_memstall;

    assign sm_idle = (w_launched != 0) && ((w_launched & ~w_exited) == 0);

    // ---------------- instruction memory ----------------
    reg [31:0] imem [0:`IMEM_WORDS-1];
    always @(posedge clk) if (imem_we) imem[imem_waddr] <= imem_wdata;

    // ---------------- scheduler ----------------
    wire                 issue_valid;
    wire [`WARP_ID_W-1:0] issue_wid;
    // barrier release: all non-exited launched warps at barrier
    wire bar_release = ((w_launched & ~w_exited & ~w_atbar) == 0) && (w_atbar != 0);

    warp_sched u_sched (
        .clk(clk), .rst(rst),
        .warp_launched(w_launched),
        .warp_exited  (w_exited),
        .warp_stalled (w_memstall | (w_atbar & {`WARPS{~bar_release}})),
        .issue_valid  (issue_valid),
        .issue_wid    (issue_wid),
        .issue_ready  (1'b1)
    );

    // ---------------- EX stage regs ----------------
    reg                  ex_v;
    reg [`WARP_ID_W-1:0] ex_wid;
    reg [31:0]           ex_ir;
    always @(posedge clk) begin
        if (rst) ex_v <= 1'b0;
        else begin
            ex_v   <= issue_valid;
            ex_wid <= issue_wid;
            ex_ir  <= imem[w_pc[issue_wid]];
        end
    end

    wire [4:0]  op  = ex_ir[31:27];
    wire [4:0]  rd  = ex_ir[26:22];
    wire [4:0]  ra  = ex_ir[21:17];
    wire [4:0]  rb  = ex_ir[16:12];
    wire [11:0] imm = ex_ir[11:0];

    // ---------------- register file ----------------
    wire [`LANES*`LANE_W-1:0] ra_d, rb_d, rc_d;
    reg                       wb_en;
    reg  [`WARP_ID_W-1:0]     wb_wid;
    reg  [`REG_AW-1:0]        wb_addr;
    reg  [`LANES-1:0]         wb_mask;
    reg  [`LANES*`LANE_W-1:0] wb_data;

    regfile u_rf (
        .clk(clk),
        .rd_wid(ex_wid), .ra_addr(ra), .rb_addr(rb), .rc_addr(rd),
        .ra_data(ra_d), .rb_data(rb_d), .rc_data(rc_d),
        .wr_en(wb_en), .wr_wid(wb_wid), .wr_addr(wb_addr),
        .wr_mask(wb_mask), .wr_data(wb_data)
    );

    // ---------------- SIMD ALU ----------------
    wire [`LANES*`LANE_W-1:0] alu_y;
    wire [`LANES-1:0]         alu_setp;
    simd_alu u_alu (.op(op), .a(ra_d), .b(rb_d), .c(rc_d),
                    .imm12(imm), .y(alu_y), .setp(alu_setp));

    // TID value per lane
    wire [`LANES*`LANE_W-1:0] tid_bus;
    genvar gl;
    generate
        for (gl = 0; gl < `LANES; gl = gl + 1) begin : tid
            assign tid_bus[gl*`LANE_W +: `LANE_W] =
                (CHIP_ID << 14) | (SM_ID << 11) | (ex_wid << 5) | gl;
        end
    endgenerate

    // ---------------- shared memory ----------------
    reg [31:0] smem [0:(`SMEM_KB*256)-1];

    // ---------------- LSU: per-lane serialisation state ----------------
    reg                  lsu_busy;
    reg [`WARP_ID_W-1:0] lsu_wid;
    reg [4:0]            lsu_rd;
    reg                  lsu_we;
    reg [5:0]            lsu_lane;
    reg [`LANES-1:0]     lsu_mask;
    reg [11:0]           lsu_imm;
    reg [`LANES*`LANE_W-1:0] lsu_addr_bus, lsu_st_bus, lsu_ld_bus;

    wire [`LANES-1:0] cur_mask = w_mask[ex_wid];
    wire signed [31:0] simm = {{20{imm[11]}}, imm};

    integer k;
    always @(posedge clk) begin
        if (rst) begin
            w_launched <= 0; w_exited <= 0; w_atbar <= 0; w_memstall <= 0;
            wb_en <= 0; lsu_busy <= 0; gmem_req <= 0;
            for (k = 0; k < `WARPS; k = k + 1) begin
                w_pc[k] <= 0; w_mask[k] <= {`LANES{1'b1}};
            end
        end else begin
            wb_en <= 1'b0;

            // ---- kernel launch ----
            if (launch) begin
                w_launched <= (1 << launch_nwarps) - 1;
                w_exited   <= 0; w_atbar <= 0; w_memstall <= 0;
                for (k = 0; k < `WARPS; k = k + 1) begin
                    w_pc[k] <= 0; w_mask[k] <= {`LANES{1'b1}};
                end
            end

            // ---- barrier release ----
            if (bar_release) w_atbar <= 0;

            // ---- EX/WB ----
            if (ex_v && !lsu_busy) begin
                case (op)
                    `OP_NOP: w_pc[ex_wid] <= w_pc[ex_wid] + 1;
                    `OP_MOVI, `OP_ADD, `OP_SUB, `OP_MUL, `OP_MAD,
                    `OP_AND, `OP_OR, `OP_XOR, `OP_SHL, `OP_SHR: begin
                        wb_en   <= 1'b1;  wb_wid  <= ex_wid;
                        wb_addr <= rd;    wb_mask <= cur_mask;
                        wb_data <= alu_y;
                        w_pc[ex_wid] <= w_pc[ex_wid] + 1;
                    end
                    `OP_TID: begin
                        wb_en <= 1'b1; wb_wid <= ex_wid; wb_addr <= rd;
                        wb_mask <= cur_mask; wb_data <= tid_bus;
                        w_pc[ex_wid] <= w_pc[ex_wid] + 1;
                    end
                    `OP_SETP: begin
                        w_mask[ex_wid] <= cur_mask & alu_setp;
                        w_pc[ex_wid]   <= w_pc[ex_wid] + 1;
                    end
                    `OP_BRA: begin
                        if (cur_mask != 0)
                            w_pc[ex_wid] <= w_pc[ex_wid] + simm[9:0];
                        else
                            w_pc[ex_wid] <= w_pc[ex_wid] + 1;
                    end
                    `OP_LDS: begin
                        wb_en <= 1'b1; wb_wid <= ex_wid; wb_addr <= rd;
                        wb_mask <= cur_mask;
                        for (k = 0; k < `LANES; k = k + 1)
                            wb_data[k*32 +: 32] <=
                                smem[(ra_d[k*32 +: 32] + simm) & ((`SMEM_KB*256)-1)];
                        w_pc[ex_wid] <= w_pc[ex_wid] + 1;
                    end
                    `OP_STS: begin
                        for (k = 0; k < `LANES; k = k + 1)
                            if (cur_mask[k])
                                smem[(ra_d[k*32 +: 32] + simm) & ((`SMEM_KB*256)-1)]
                                    <= rb_d[k*32 +: 32];
                        w_pc[ex_wid] <= w_pc[ex_wid] + 1;
                    end
                    `OP_LDG, `OP_STG: begin      // hand to LSU, stall warp
                        lsu_busy <= 1'b1;  lsu_wid <= ex_wid;
                        lsu_rd   <= rd;    lsu_we  <= (op == `OP_STG);
                        lsu_lane <= 0;     lsu_mask <= cur_mask;
                        lsu_imm  <= imm;
                        lsu_addr_bus <= ra_d;  lsu_st_bus <= rb_d;
                        w_memstall[ex_wid] <= 1'b1;
                        w_pc[ex_wid] <= w_pc[ex_wid] + 1;
                    end
                    `OP_BAR: begin
                        w_atbar[ex_wid] <= 1'b1;
                        w_pc[ex_wid]    <= w_pc[ex_wid] + 1;
                    end
                    `OP_EXIT: w_exited[ex_wid] <= 1'b1;
                    default:  w_pc[ex_wid] <= w_pc[ex_wid] + 1;
                endcase
            end

            // ---- LSU: serialise active lanes to L2 ----
            if (lsu_busy) begin
                if (lsu_lane == `LANES) begin           // all lanes done
                    lsu_busy <= 1'b0;
                    w_memstall[lsu_wid] <= 1'b0;
                    if (!lsu_we) begin                  // write back loads
                        wb_en <= 1'b1; wb_wid <= lsu_wid; wb_addr <= lsu_rd;
                        wb_mask <= lsu_mask; wb_data <= lsu_ld_bus;
                    end
                end else if (!lsu_mask[lsu_lane[4:0]]) begin
                    lsu_lane <= lsu_lane + 1;           // predicated-off lane
                end else if (!gmem_req) begin
                    gmem_req   <= 1'b1;
                    gmem_we    <= lsu_we;
                    gmem_addr  <= lsu_addr_bus[lsu_lane[4:0]*32 +: 32]
                                  + {{20{lsu_imm[11]}}, lsu_imm};
                    gmem_wdata <= lsu_st_bus[lsu_lane[4:0]*32 +: 32];
                end else if (gmem_ack) begin
                    gmem_req <= 1'b0;
                    lsu_ld_bus[lsu_lane[4:0]*32 +: 32] <= gmem_rdata;
                    lsu_lane <= lsu_lane + 1;
                end
            end
        end
    end
endmodule
