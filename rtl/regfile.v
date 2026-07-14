// ============================================================================
// AURORA register file: WARPS x NUM_REGS x LANES x 32b.
// Two read ports + one write port per warp-instruction (ra, rb; wr rd).
// Flop-based here; in silicon this maps to per-lane SRAM/latch macros --
// the wrapper keeps the same interface so macros drop in without RTL change.
// ============================================================================
`include "aurora_pkg.vh"

module regfile (
    input  wire                       clk,
    // read (combinational, EX stage registers downstream)
    input  wire [`WARP_ID_W-1:0]      rd_wid,
    input  wire [`REG_AW-1:0]         ra_addr,
    input  wire [`REG_AW-1:0]         rb_addr,
    input  wire [`REG_AW-1:0]         rc_addr,     // rd-old for MAD
    output wire [`LANES*`LANE_W-1:0]  ra_data,
    output wire [`LANES*`LANE_W-1:0]  rb_data,
    output wire [`LANES*`LANE_W-1:0]  rc_data,
    // write (per-lane enable = active mask)
    input  wire                       wr_en,
    input  wire [`WARP_ID_W-1:0]      wr_wid,
    input  wire [`REG_AW-1:0]         wr_addr,
    input  wire [`LANES-1:0]          wr_mask,
    input  wire [`LANES*`LANE_W-1:0]  wr_data
);
    reg [`LANES*`LANE_W-1:0] mem [0:`WARPS*`NUM_REGS-1];

    assign ra_data = mem[{rd_wid, ra_addr}];
    assign rb_data = mem[{rd_wid, rb_addr}];
    assign rc_data = mem[{rd_wid, rc_addr}];

    integer l;
    always @(posedge clk) begin
        if (wr_en) begin
            for (l = 0; l < `LANES; l = l + 1)
                if (wr_mask[l])
                    mem[{wr_wid, wr_addr}][l*`LANE_W +: `LANE_W]
                        <= wr_data[l*`LANE_W +: `LANE_W];
        end
    end
endmodule
