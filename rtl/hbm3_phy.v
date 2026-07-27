// ============================================================================
// HBM3 pseudo-channel PHY boundary.
// Same discipline as the SRAM macro: under AURORA_SIM this is a behavioral
// data-store; for synthesis it is an interface-correct empty shell, because a
// real HBM PHY is vendor hard IP. Its area/energy enter the PPA story as
// declared literature bounding numbers (see README), never as synthesized
// logic pretending to be a PHY.
// Capacity note: the behavioral store holds 64 KB -- a CAPACITY model
// boundary. Timing (banks/rows) is modeled in hbm_ctrl from the full
// address, so access *behavior* is HBM-shaped even though the store wraps.
// ============================================================================

module hbm3_phy (
    input  wire        clk,
    input  wire        wr_en,
    input  wire        rd_en,
    input  wire [13:0] waddr,     // word address into the backing store
    input  wire [31:0] wdata,
    output reg  [31:0] rdata
);
`ifdef AURORA_SIM
    reg [31:0] store [0:16383];
    always @(posedge clk) begin
        if (wr_en) store[waddr] <= wdata;
        if (rd_en) rdata <= store[waddr];
    end
`else
    // hard-IP boundary: intentionally empty for synthesis
`endif
endmodule
