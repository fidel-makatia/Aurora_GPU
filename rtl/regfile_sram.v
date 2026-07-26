// ============================================================================
// AURORA register file v2: banked 1R1W SRAM macros.
// 3 read copies (ra/rb/rc) x 4 banks of 256b => 12 macros; writes broadcast.
// Reads are ISSUE-stage (synchronous): data valid throughout the EX cycle.
// Per-lane write masking is done upstream (WB composes mask?new:old), so
// writes are full 1024b rows.
// ============================================================================
`include "aurora_pkg.vh"

module regfile (
    input  wire                       clk,
    // ISSUE-stage read (synchronous; outputs valid next cycle = EX)
    input  wire                       rd_en,
    input  wire [`WARP_ID_W-1:0]      rd_wid,
    input  wire [`REG_AW-1:0]         ra_addr,
    input  wire [`REG_AW-1:0]         rb_addr,
    input  wire [`REG_AW-1:0]         rc_addr,
    output wire [`LANES*`LANE_W-1:0]  ra_data,
    output wire [`LANES*`LANE_W-1:0]  rb_data,
    output wire [`LANES*`LANE_W-1:0]  rc_data,
    // WB-stage write (full row; masking composed upstream)
    input  wire                       wr_en,
    input  wire [`WARP_ID_W-1:0]      wr_wid,
    input  wire [`REG_AW-1:0]         wr_addr,
    input  wire [`LANES*`LANE_W-1:0]  wr_data
);
    wire [7:0] r_row [0:2];
    assign r_row[0] = {rd_wid, ra_addr};
    assign r_row[1] = {rd_wid, rb_addr};
    assign r_row[2] = {rd_wid, rc_addr};
    wire [7:0] w_row = {wr_wid, wr_addr};

    wire [`LANES*`LANE_W-1:0] rdata [0:2];
    assign ra_data = rdata[0];
    assign rb_data = rdata[1];
    assign rc_data = rdata[2];

    genvar c, b;
    generate
      for (c = 0; c < 3; c = c + 1) begin : copy
        for (b = 0; b < 4; b = b + 1) begin : bank
          wire [271:0] q;
          sram_1r1w_272_256_asap7 u_m (
            .clk(clk),
            .r0_ce_in(rd_en),
            .r0_addr_in(r_row[c]),
            .r0_rd_out(q),
            .w0_ce_in(wr_en),
            .w0_we_in(wr_en),
            .w0_addr_in(w_row),
            .w0_wd_in({16'b0, wr_data[b*256 +: 256]})
          );
          assign rdata[c][b*256 +: 256] = q[255:0];
        end
      end
    endgenerate
endmodule
