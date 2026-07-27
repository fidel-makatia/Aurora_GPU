// ============================================================================
// HBM3 pseudo-channel memory controller (one PC: 64b DQ @ 6.4 Gbps class
// = 51.2 GB/s -- a good match for Aurora's serialized ~64 GB/s demand; the
// full-stack 16-PC step is gated on L2 coalescing, see README roadmap).
//
// Real, synthesizable controller logic: 16 banks (word-interleaved), per-bank
// open-row tracking, in-order single-outstanding scheduling with open-page
// policy. Timing parameters are HBM3-class in 1 GHz controller cycles:
//   row hit   : tCL + burst
//   row miss  : tRP + tRCD + tCL + burst   (precharge, activate, then CAS)
//   bank idle : tRCD + tCL + burst         (activate, then CAS)
// In-order + single-outstanding is deterministic and matches the upstream
// fabric (SM LSUs serialize; the hub serves one client at a time). FR-FCFS
// reordering is a roadmap item, meaningful only after L2 coalescing.
// ============================================================================

module hbm_ctrl #(
    parameter TRCD   = 14,        // activate -> column command
    parameter TRP    = 14,        // precharge period
    parameter TCL    = 14,        // CAS latency
    parameter TBURST = 2          // BL8 on 64b DQ, 1 GHz controller clock
)(
    input  wire        clk,
    input  wire        rst,
    // request port: level-held req, single-cycle done pulse
    input  wire        req,
    input  wire        we,
    input  wire [31:0] addr,
    input  wire [31:0] wdata,
    output reg         done,
    output reg  [31:0] rdata
);
    // word-interleaved bank map: consecutive words stripe across all 16
    // banks (streaming-friendly); row from higher bits
    wire [3:0]  bank = addr[5:2];
    wire [13:0] row  = addr[19:6];

    reg [13:0] open_row [0:15];
    reg [15:0] open_v;

    localparam S_IDLE = 3'd0, S_PRE = 3'd1, S_ACT = 3'd2,
               S_CAS = 3'd3, S_REL = 3'd4;
    reg [2:0] st;
    reg [5:0] cnt;

    wire        phy_wr = (st == S_CAS) && (cnt == 1) && we;
    wire        phy_rd = (st == S_CAS) && (cnt == 2) && !we;
    wire [31:0] phy_q;

    hbm3_phy u_phy (
        .clk(clk), .wr_en(phy_wr), .rd_en(phy_rd),
        .waddr(addr[15:2]), .wdata(wdata), .rdata(phy_q)
    );

    always @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE; done <= 0; open_v <= 16'b0;
        end else begin
            done <= 0;
            case (st)
                S_IDLE: if (req) begin
                    if (!open_v[bank]) begin
                        cnt <= TRCD;                 st <= S_ACT;
                    end else if (open_row[bank] != row) begin
                        cnt <= TRP;                  st <= S_PRE;
                    end else begin
                        cnt <= TCL + TBURST;         st <= S_CAS;
                    end
                end
                S_PRE: begin
                    cnt <= cnt - 1;
                    if (cnt == 1) begin cnt <= TRCD; st <= S_ACT; end
                end
                S_ACT: begin
                    cnt <= cnt - 1;
                    if (cnt == 1) begin
                        open_row[bank] <= row;
                        open_v[bank]   <= 1'b1;
                        cnt <= TCL + TBURST;         st <= S_CAS;
                    end
                end
                S_CAS: begin
                    cnt <= cnt - 1;
                    if (cnt == 1) begin
                        rdata <= phy_q;
                        done  <= 1'b1;
                        st    <= S_REL;
                    end
                end
                S_REL: if (!req) st <= S_IDLE;   // master saw done, dropped req
            endcase
        end
    end
endmodule
