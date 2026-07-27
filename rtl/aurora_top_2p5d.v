// ============================================================================
// AURORA 2.5D assembly: 1 IO/hub die + NUM_CCHIP compute dies on interposer.
// In physical implementation each chiplet is a separate ASAP7 P&R block and
// the d2d_* nets become F2F ubump arrays (SenseEdge chiplet flow). This top
// is the logical stitching used for full-system simulation and for the
// monolithic-reference synthesis run.
// ============================================================================
`include "aurora_pkg.vh"

module aurora_top_2p5d (
    input  wire        clk,
    input  wire        rst,
    input  wire        cpu_en,    // strap: RV32 command processor self-boot
    // Wishbone host
    input  wire        wb_stb,
    input  wire        wb_we,
    input  wire [31:0] wb_adr,
    input  wire [31:0] wb_dat_i,
    output wire [31:0] wb_dat_o,
    output wire        wb_ack,
    output wire        gpu_idle,
    // on-die RV32 command processor result mmio
    output wire        fw_done,
    output wire [31:0] fw_result
);
    // sideband
    wire                    cc_launch;
    wire [`WARP_ID_W:0]     cc_nwarps;
    wire                    cc_imem_we;
    wire [1:0]              cc_imem_sm;
    wire [9:0]              cc_imem_waddr;
    wire [31:0]             cc_imem_wdata;
    wire [`NUM_CCHIP-1:0]   cc_idle;

    // D2D interposer nets
    wire [`NUM_CCHIP*16-1:0] cc2hub_d, hub2cc_d;
    wire [`NUM_CCHIP-1:0]    cc2hub_v, hub2cc_v;

    io_chiplet u_hub (
        .clk(clk), .rst(rst), .cpu_en(cpu_en),
        .wb_stb(wb_stb), .wb_we(wb_we), .wb_adr(wb_adr),
        .wb_dat_i(wb_dat_i), .wb_dat_o(wb_dat_o), .wb_ack(wb_ack),
        .fw_done(fw_done), .fw_result(fw_result),
        .cc_launch(cc_launch), .cc_nwarps(cc_nwarps),
        .cc_imem_we(cc_imem_we), .cc_imem_sm(cc_imem_sm),
        .cc_imem_waddr(cc_imem_waddr), .cc_imem_wdata(cc_imem_wdata),
        .cc_idle(cc_idle),
        .d2d_rx_d(cc2hub_d), .d2d_rx_v(cc2hub_v),
        .d2d_tx_d(hub2cc_d), .d2d_tx_v(hub2cc_v)
    );

    genvar c;
    generate
        for (c = 0; c < `NUM_CCHIP; c = c + 1) begin : cc
            compute_chiplet #(.CHIP_ID(c)) u_cc (
                .clk(clk), .rst(rst),
                .launch(cc_launch), .launch_nwarps(cc_nwarps),
                .imem_we(cc_imem_we), .imem_sm(cc_imem_sm),
                .imem_waddr(cc_imem_waddr), .imem_wdata(cc_imem_wdata),
                .chip_idle(cc_idle[c]),
                .d2d_tx_d(cc2hub_d[c*16 +: 16]), .d2d_tx_v(cc2hub_v[c]),
                .d2d_rx_d(hub2cc_d[c*16 +: 16]), .d2d_rx_v(hub2cc_v[c])
            );
        end
    endgenerate

    assign gpu_idle = &cc_idle;
endmodule
