// ============================================================================
// AURORA SIMD ALU: LANES x 32-bit integer lanes with MAD support.
// One warp-instruction per cycle; per-lane predication by active mask.
// ============================================================================
`include "aurora_pkg.vh"

module simd_alu (
    input  wire [4:0]                 op,
    input  wire [`LANES*`LANE_W-1:0]  a,       // ra operand, all lanes
    input  wire [`LANES*`LANE_W-1:0]  b,       // rb operand
    input  wire [`LANES*`LANE_W-1:0]  c,       // rd old value (for MAD)
    input  wire [11:0]                imm12,
    output wire [`LANES*`LANE_W-1:0]  y,       // result
    output wire [`LANES-1:0]          setp     // per-lane predicate (SETP)
);
    wire [`LANE_W-1:0] simm = {{20{imm12[11]}}, imm12};

    genvar l;
    generate
        for (l = 0; l < `LANES; l = l + 1) begin : lane
            wire [`LANE_W-1:0] la = a[l*`LANE_W +: `LANE_W];
            wire [`LANE_W-1:0] lb = b[l*`LANE_W +: `LANE_W];
            wire [`LANE_W-1:0] lc = c[l*`LANE_W +: `LANE_W];

            reg  [`LANE_W-1:0] r;
            always @* begin
                case (op)
                    `OP_MOVI: r = simm;
                    `OP_ADD:  r = la + lb;
                    `OP_SUB:  r = la - lb;
                    `OP_MUL:  r = la * lb;
                    `OP_MAD:  r = la * lb + lc;
                    `OP_AND:  r = la & lb;
                    `OP_OR:   r = la | lb;
                    `OP_XOR:  r = la ^ lb;
                    `OP_SHL:  r = la << lb[4:0];
                    `OP_SHR:  r = la >> lb[4:0];
                    default:  r = {`LANE_W{1'b0}};
                endcase
            end
            assign y[l*`LANE_W +: `LANE_W] = r;
            assign setp[l] = ($signed(la) < $signed(lb));
        end
    endgenerate
endmodule
