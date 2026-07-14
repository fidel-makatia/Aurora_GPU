// ============================================================================
// AURORA IO/host chiplet ("hub" die):
//  - Wishbone host slave: kernel upload, launch, status, DRAM window
//  - command processor: broadcasts imem writes + launch to compute chiplets
//    over sideband, aggregates idle status
//  - global memory controller: round-robin over NUM_CCHIP D2D endpoints,
//    backed by an on-die scratch acting as the DRAM model boundary (a real
//    flagship replaces this bank with an HBM/LPDDR PHY + controller IP).
// ============================================================================
`include "aurora_pkg.vh"

module io_chiplet #(
    parameter GMEM_WORDS = 16384
)(
    input  wire        clk,
    input  wire        rst,
    // Wishbone host
    input  wire        wb_stb,
    input  wire        wb_we,
    input  wire [31:0] wb_adr,
    input  wire [31:0] wb_dat_i,
    output reg  [31:0] wb_dat_o,
    output reg         wb_ack,
    // sideband to compute chiplets
    output reg                     cc_launch,
    output reg [`WARP_ID_W:0]      cc_nwarps,
    output reg                     cc_imem_we,
    output reg [1:0]               cc_imem_sm,
    output reg [9:0]               cc_imem_waddr,
    output reg [31:0]              cc_imem_wdata,
    input  wire [`NUM_CCHIP-1:0]   cc_idle,
    // D2D physical pins, one endpoint per compute chiplet
    input  wire [`NUM_CCHIP*16-1:0] d2d_rx_d,
    input  wire [`NUM_CCHIP-1:0]    d2d_rx_v,
    output wire [`NUM_CCHIP*16-1:0] d2d_tx_d,
    output wire [`NUM_CCHIP-1:0]    d2d_tx_v
);
    // ---------------- global memory (DRAM-model boundary) ----------------
    reg [31:0] gmem [0:GMEM_WORDS-1];

    // ---------------- D2D endpoints ----------------
    wire [`NUM_CCHIP-1:0]  ep_req, ep_we;
    wire [`NUM_CCHIP*32-1:0] ep_addr, ep_wdata;
    reg  [`NUM_CCHIP-1:0]  ep_ack;
    reg  [31:0]            ep_rdata;

    genvar c;
    generate
        for (c = 0; c < `NUM_CCHIP; c = c + 1) begin : ep
            d2d_rx u_rx (
                .clk(clk), .rst(rst),
                .rx_d(d2d_rx_d[c*16 +: 16]), .rx_v(d2d_rx_v[c]),
                .tx_d(d2d_tx_d[c*16 +: 16]), .tx_v(d2d_tx_v[c]),
                .req(ep_req[c]), .we(ep_we[c]),
                .addr (ep_addr [c*32 +: 32]),
                .wdata(ep_wdata[c*32 +: 32]),
                .ack(ep_ack[c]), .rdata(ep_rdata)
            );
        end
    endgenerate

    // ---------------- memory controller: round-robin ----------------
    reg [1:0] mgrant;
    integer i;
    reg [1:0] mnxt; reg mfound;
    always @* begin
        mnxt = mgrant; mfound = 0;
        for (i = 1; i <= `NUM_CCHIP; i = i + 1)
            if (!mfound && ep_req[(mgrant + i) % `NUM_CCHIP]) begin
                mnxt = (mgrant + i) % `NUM_CCHIP; mfound = 1;
            end
    end

    wire [31:0] m_addr  = ep_addr [mgrant*32 +: 32];
    wire [31:0] m_wdata = ep_wdata[mgrant*32 +: 32];

    reg m_busy;
    always @(posedge clk) begin
        if (rst) begin
            mgrant <= 0; m_busy <= 0; ep_ack <= 0;
        end else begin
            ep_ack <= 0;
            if (!m_busy) begin
                if (mfound) begin mgrant <= mnxt; m_busy <= 1'b1; end
            end else begin
                if (ep_we[mgrant]) gmem[m_addr[15:2]] <= m_wdata;
                ep_rdata       <= gmem[m_addr[15:2]];
                ep_ack[mgrant] <= 1'b1;
                m_busy         <= 1'b0;
            end
        end
    end

    // ---------------- host register map ----------------
    // 0x0000_0000 +: gmem window (word)         RW
    // 0x4000_0000: imem write {sm[1:0]=adr[13:12], addr=adr[11:2]}  W
    // 0x8000_0000: launch, dat = nwarps          W
    // 0x8000_0004: status, bit0 = all idle       R
    always @(posedge clk) begin
        if (rst) begin
            wb_ack <= 0; cc_launch <= 0; cc_imem_we <= 0;
        end else begin
            wb_ack     <= 0;
            cc_launch  <= 0;
            cc_imem_we <= 0;
            if (wb_stb && !wb_ack) begin
                wb_ack <= 1'b1;
                case (wb_adr[31:28])
                    4'h0: begin
                        if (wb_we) gmem[wb_adr[15:2]] <= wb_dat_i;
                        wb_dat_o <= gmem[wb_adr[15:2]];
                    end
                    4'h4: begin
                        cc_imem_we    <= wb_we;
                        cc_imem_sm    <= wb_adr[13:12];
                        cc_imem_waddr <= wb_adr[11:2];
                        cc_imem_wdata <= wb_dat_i;
                    end
                    4'h8: begin
                        if (wb_adr[3:0] == 4'h0 && wb_we) begin
                            cc_launch <= 1'b1;
                            cc_nwarps <= wb_dat_i[`WARP_ID_W:0];
                        end else
                            wb_dat_o <= {31'b0, &cc_idle};
                    end
                    default: wb_dat_o <= 32'hDEAD_BEEF;
                endcase
            end
        end
    end
endmodule
