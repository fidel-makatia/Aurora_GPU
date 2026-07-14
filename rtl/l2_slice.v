// ============================================================================
// AURORA L2 slice: per-chiplet arbiter + local scratch bank + D2D forward.
// Address map: bit31=0 -> local slice bank (chiplet-local scratch)
//              bit31=1 -> forward over D2D to IO chiplet (global DRAM space)
// Round-robin over SM ports; single outstanding remote request.
// Local bank is flop-based here with an SRAM-macro drop-in boundary.
// ============================================================================
`include "aurora_pkg.vh"

module l2_slice #(
    parameter BANK_WORDS = 4096
)(
    input  wire        clk,
    input  wire        rst,
    // SM ports
    input  wire [`SMS_PER_CHIP-1:0]      sm_req,
    input  wire [`SMS_PER_CHIP-1:0]      sm_we,
    input  wire [`SMS_PER_CHIP*32-1:0]   sm_addr,
    input  wire [`SMS_PER_CHIP*32-1:0]   sm_wdata,
    output reg  [`SMS_PER_CHIP-1:0]      sm_ack,
    output reg  [31:0]                   sm_rdata,   // shared rdata bus (ack qualifies)
    // remote (D2D to IO chiplet) request port
    output reg         rem_req,
    output reg         rem_we,
    output reg  [31:0] rem_addr,
    output reg  [31:0] rem_wdata,
    input  wire        rem_ack,
    input  wire [31:0] rem_rdata
);
    reg [31:0] bank [0:BANK_WORDS-1];

    reg [1:0]  grant;      // current SM
    reg        busy, remote;

    wire [31:0] g_addr  = sm_addr [grant*32 +: 32];
    wire [31:0] g_wdata = sm_wdata[grant*32 +: 32];
    wire        g_we    = sm_we[grant];

    integer i;
    reg [1:0] nxt;
    reg       found;
    always @* begin           // round-robin pick
        nxt = grant; found = 1'b0;
        for (i = 1; i <= `SMS_PER_CHIP; i = i + 1)
            if (!found && sm_req[(grant + i) % `SMS_PER_CHIP]) begin
                nxt   = (grant + i) % `SMS_PER_CHIP;
                found = 1'b1;
            end
    end

    always @(posedge clk) begin
        if (rst) begin
            grant <= 0; busy <= 0; remote <= 0;
            sm_ack <= 0; rem_req <= 0;
        end else begin
            sm_ack <= 0;
            if (!busy) begin
                if (found) begin grant <= nxt; busy <= 1'b1; end
            end else if (!remote) begin
                if (g_addr[31]) begin                 // global -> D2D
                    remote    <= 1'b1;
                    rem_req   <= 1'b1;
                    rem_we    <= g_we;
                    rem_addr  <= g_addr;
                    rem_wdata <= g_wdata;
                end else begin                        // local bank hit
                    if (g_we) bank[g_addr[13:2]] <= g_wdata;
                    sm_rdata      <= bank[g_addr[13:2]];
                    sm_ack[grant] <= 1'b1;
                    busy          <= 1'b0;
                end
            end else if (rem_ack) begin
                rem_req       <= 1'b0;
                sm_rdata      <= rem_rdata;
                sm_ack[grant] <= 1'b1;
                busy          <= 1'b0;
                remote        <= 1'b0;
            end
        end
    end
endmodule
