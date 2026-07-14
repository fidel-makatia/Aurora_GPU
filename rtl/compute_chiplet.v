// ============================================================================
// AURORA compute chiplet: SMS_PER_CHIP SMs + L2 slice + D2D endpoint.
// This is the physical die that gets its own ASAP7 P&R run; the D2D pins
// map to interposer ubumps (F2F) exactly like the SenseEdge chiplet study.
// ============================================================================
`include "aurora_pkg.vh"

module compute_chiplet #(
    parameter CHIP_ID = 0
)(
    input  wire        clk,
    input  wire        rst,
    // kernel control (from IO chiplet over sideband)
    input  wire        launch,
    input  wire [`WARP_ID_W:0] launch_nwarps,
    input  wire        imem_we,
    input  wire [1:0]  imem_sm,          // which SM's imem (broadcast if 2'b11)
    input  wire [9:0]  imem_waddr,
    input  wire [31:0] imem_wdata,
    output wire        chip_idle,
    // D2D physical pins to IO chiplet
    output wire [15:0] d2d_tx_d,
    output wire        d2d_tx_v,
    input  wire [15:0] d2d_rx_d,
    input  wire        d2d_rx_v
);
    // ---------------- SMs ----------------
    wire [`SMS_PER_CHIP-1:0]    sm_req,  sm_we,  sm_ack, sm_idle;
    wire [`SMS_PER_CHIP*32-1:0] sm_addr, sm_wdata;
    wire [31:0]                 sm_rdata;

    genvar s;
    generate
        for (s = 0; s < `SMS_PER_CHIP; s = s + 1) begin : sm
            sm_core #(.SM_ID(s), .CHIP_ID(CHIP_ID)) u_sm (
                .clk(clk), .rst(rst),
                .launch(launch), .launch_nwarps(launch_nwarps),
                .imem_we(imem_we && ((imem_sm == (s % 4)) || (imem_sm == 2'b11))),
                .imem_waddr(imem_waddr), .imem_wdata(imem_wdata),
                .sm_idle(sm_idle[s]),
                .gmem_req(sm_req[s]), .gmem_we(sm_we[s]),
                .gmem_addr (sm_addr [s*32 +: 32]),
                .gmem_wdata(sm_wdata[s*32 +: 32]),
                .gmem_ack(sm_ack[s]), .gmem_rdata(sm_rdata)
            );
        end
    endgenerate
    assign chip_idle = &sm_idle;

    // ---------------- L2 slice ----------------
    wire        rem_req, rem_we, rem_ack;
    wire [31:0] rem_addr, rem_wdata, rem_rdata;

    l2_slice u_l2 (
        .clk(clk), .rst(rst),
        .sm_req(sm_req), .sm_we(sm_we), .sm_addr(sm_addr), .sm_wdata(sm_wdata),
        .sm_ack(sm_ack), .sm_rdata(sm_rdata),
        .rem_req(rem_req), .rem_we(rem_we), .rem_addr(rem_addr),
        .rem_wdata(rem_wdata), .rem_ack(rem_ack), .rem_rdata(rem_rdata)
    );

    // ---------------- D2D endpoint ----------------
    d2d_tx u_d2d (
        .clk(clk), .rst(rst),
        .req(rem_req), .we(rem_we), .addr(rem_addr), .wdata(rem_wdata),
        .ack(rem_ack), .rdata(rem_rdata),
        .tx_d(d2d_tx_d), .tx_v(d2d_tx_v), .rx_d(d2d_rx_d), .rx_v(d2d_rx_v)
    );
endmodule
