// ============================================================================
// AURORA warp scheduler: round-robin over ready warps.
// A warp is ready when: launched, not exited, not stalled on memory/barrier.
// Issues one warp-instruction per cycle to the SIMD pipeline.
// ============================================================================
`include "aurora_pkg.vh"

module warp_sched (
    input  wire                 clk,
    input  wire                 rst,
    // launch/exit/stall status per warp
    input  wire [`WARPS-1:0]    warp_launched,
    input  wire [`WARPS-1:0]    warp_exited,
    input  wire [`WARPS-1:0]    warp_stalled,   // mem pending or barrier wait
    // issue interface
    output reg                  issue_valid,
    output reg  [`WARP_ID_W-1:0] issue_wid,
    input  wire                 issue_ready     // pipeline accepts
);
    wire [`WARPS-1:0] ready = warp_launched & ~warp_exited & ~warp_stalled;

    reg [`WARP_ID_W-1:0] rr_ptr;

    // rotate-left ready vector by rr_ptr, priority-encode, rotate back
    integer i;
    reg [`WARP_ID_W-1:0] pick;
    reg                  found;
    always @* begin
        pick  = {`WARP_ID_W{1'b0}};
        found = 1'b0;
        for (i = 0; i < `WARPS; i = i + 1) begin : scan
            // candidate = rr_ptr + i (mod WARPS)
            if (!found && ready[(rr_ptr + i) % `WARPS]) begin
                pick  = (rr_ptr + i) % `WARPS;
                found = 1'b1;
            end
        end
        issue_valid = found;
        issue_wid   = pick;
    end

    always @(posedge clk) begin
        if (rst)
            rr_ptr <= {`WARP_ID_W{1'b0}};
        else if (issue_valid && issue_ready)
            rr_ptr <= (issue_wid + 1'b1) % `WARPS;   // fair rotation
    end
endmodule
