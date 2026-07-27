// ============================================================================
// AURORA host CPU: RV32I + M-multiply (Zmmul), multi-cycle.
// The on-die command processor: boots from the hub's boot RAM, uploads GPU
// kernels, launches them, polls idle -- Aurora as a self-contained SoC.
//
// Von Neumann: one bus master port carries both fetch and data. A simple
// 4-state FSM (FETCH -> EXEC -> MEM -> WB) keeps the core tiny and closes
// timing trivially at the GPU's 1 GHz; a command processor is latency-, not
// throughput-critical. Unimplemented: DIV/REM, CSRs, interrupts, exceptions
// (FENCE/ECALL/EBREAK retire as NOPs) -- see README roadmap.
// ============================================================================
`include "aurora_pkg.vh"

module riscv_core #(
    parameter RESET_PC = 32'h0000_0000
)(
    input  wire        clk,
    input  wire        rst,
    // bus master (fetch + data)
    output reg         bus_req,
    output reg         bus_we,
    output reg  [31:0] bus_addr,
    output reg  [31:0] bus_wdata,
    output reg  [3:0]  bus_be,
    input  wire        bus_ack,
    input  wire [31:0] bus_rdata
);
    // ---------------- state ----------------
    localparam S_FETCH = 2'd0, S_EXEC = 2'd1, S_MEM = 2'd2, S_WB = 2'd3;
    reg [1:0]  state;
    reg [31:0] pc, ir;
    reg [31:0] x [0:31];                 // register file (x0 read forced 0)
    reg [31:0] load_val;

    // ---------------- decode ----------------
    wire [6:0] opc    = ir[6:0];
    wire [4:0] rd     = ir[11:7];
    wire [2:0] f3     = ir[14:12];
    wire [4:0] rs1    = ir[19:15];
    wire [4:0] rs2    = ir[24:20];
    wire [6:0] f7     = ir[31:25];

    wire [31:0] imm_i = {{20{ir[31]}}, ir[31:20]};
    wire [31:0] imm_s = {{20{ir[31]}}, ir[31:25], ir[11:7]};
    wire [31:0] imm_b = {{19{ir[31]}}, ir[31], ir[7], ir[30:25], ir[11:8], 1'b0};
    wire [31:0] imm_u = {ir[31:12], 12'b0};
    wire [31:0] imm_j = {{11{ir[31]}}, ir[31], ir[19:12], ir[20], ir[30:21], 1'b0};

    wire [31:0] a = (rs1 == 0) ? 32'b0 : x[rs1];
    wire [31:0] b = (rs2 == 0) ? 32'b0 : x[rs2];

    localparam OP_LUI = 7'h37, OP_AUIPC = 7'h17, OP_JAL = 7'h6F,
               OP_JALR = 7'h67, OP_BR = 7'h63, OP_LD = 7'h03,
               OP_ST = 7'h23, OP_IMM = 7'h13, OP_REG = 7'h33;

    // ---------------- ALU ----------------
    wire is_imm  = (opc == OP_IMM);
    wire [31:0] opb = is_imm ? imm_i : b;
    wire [4:0]  sh  = is_imm ? rs2 : b[4:0];
    wire is_mul  = (opc == OP_REG) && (f7 == 7'h01);

    wire signed [63:0] mss = $signed(a) * $signed(b);
    wire        [63:0] muu = {32'b0, a} * {32'b0, b};
    wire signed [63:0] msu = $signed(a) * $signed({1'b0, b});

    reg [31:0] alu;
    always @* begin
        if (is_mul) begin
            case (f3)
                3'd0: alu = mss[31:0];            // MUL
                3'd1: alu = mss[63:32];           // MULH
                3'd2: alu = msu[63:32];           // MULHSU
                3'd3: alu = muu[63:32];           // MULHU
                default: alu = 32'b0;             // DIV/REM unimplemented
            endcase
        end else begin
            case (f3)
                3'd0: alu = (!is_imm && f7[5]) ? a - opb : a + opb;
                3'd1: alu = a << sh;
                3'd2: alu = ($signed(a) < $signed(opb)) ? 32'd1 : 32'd0;
                3'd3: alu = (a < opb) ? 32'd1 : 32'd0;
                3'd4: alu = a ^ opb;
                3'd5: alu = f7[5] ? ($signed(a) >>> sh) : (a >> sh);
                3'd6: alu = a | opb;
                default: alu = a & opb;
            endcase
        end
    end

    // ---------------- branch condition ----------------
    reg br_take;
    always @* begin
        case (f3)
            3'd0: br_take = (a == b);
            3'd1: br_take = (a != b);
            3'd4: br_take = ($signed(a) <  $signed(b));
            3'd5: br_take = ($signed(a) >= $signed(b));
            3'd6: br_take = (a < b);
            3'd7: br_take = (a >= b);
            default: br_take = 1'b0;
        endcase
    end

    // ---------------- load/store lane helpers ----------------
    wire [31:0] mem_addr = a + ((opc == OP_ST) ? imm_s : imm_i);
    reg  [3:0]  st_be;
    reg  [31:0] st_data;
    always @* begin
        case (f3[1:0])
            2'd0: begin st_be = 4'b0001 << mem_addr[1:0];
                        st_data = {4{b[7:0]}};   end
            2'd1: begin st_be = mem_addr[1] ? 4'b1100 : 4'b0011;
                        st_data = {2{b[15:0]}};  end
            default: begin st_be = 4'b1111; st_data = b; end
        endcase
    end

    reg [31:0] ld_ext;
    always @* begin
        case (f3[1:0])
            2'd0: begin : byte_sel
                reg [7:0] lb;
                lb = bus_rdata >> (8 * bus_addr[1:0]);
                ld_ext = f3[2] ? {24'b0, lb} : {{24{lb[7]}}, lb};
            end
            2'd1: begin : half_sel
                reg [15:0] lh;
                lh = bus_addr[1] ? bus_rdata[31:16] : bus_rdata[15:0];
                ld_ext = f3[2] ? {16'b0, lh} : {{16{lh[15]}}, lh};
            end
            default: ld_ext = bus_rdata;
        endcase
    end

    // ---------------- FSM ----------------
    integer k;
    always @(posedge clk) begin
        if (rst) begin
            state <= S_FETCH; pc <= RESET_PC;
            bus_req <= 0; bus_we <= 0;
            for (k = 0; k < 32; k = k + 1) x[k] <= 32'b0;
        end else begin
            case (state)
                S_FETCH: begin
                    bus_req <= 1'b1; bus_we <= 1'b0;
                    bus_addr <= pc; bus_be <= 4'b1111;
                    if (bus_req && bus_ack) begin
                        bus_req <= 1'b0;
                        ir      <= bus_rdata;
                        state   <= S_EXEC;
                    end
                end
                S_EXEC: begin
                    case (opc)
                        OP_LUI: begin
                            if (rd != 0) x[rd] <= imm_u;
                            pc <= pc + 4; state <= S_FETCH;
                        end
                        OP_AUIPC: begin
                            if (rd != 0) x[rd] <= pc + imm_u;
                            pc <= pc + 4; state <= S_FETCH;
                        end
                        OP_JAL: begin
                            if (rd != 0) x[rd] <= pc + 4;
                            pc <= pc + imm_j; state <= S_FETCH;
                        end
                        OP_JALR: begin
                            if (rd != 0) x[rd] <= pc + 4;
                            pc <= (a + imm_i) & ~32'b1; state <= S_FETCH;
                        end
                        OP_BR: begin
                            pc <= br_take ? pc + imm_b : pc + 4;
                            state <= S_FETCH;
                        end
                        OP_LD: begin
                            bus_req <= 1'b1; bus_we <= 1'b0;
                            bus_addr <= mem_addr;    // slaves select on [.,2];
                            bus_be   <= 4'b1111;     // [1:0] keys ld_ext lane
                            state <= S_MEM;
                        end
                        OP_ST: begin
                            bus_req <= 1'b1; bus_we <= 1'b1;
                            bus_addr <= {mem_addr[31:2], 2'b00};
                            bus_wdata <= st_data; bus_be <= st_be;
                            state <= S_MEM;
                        end
                        OP_IMM, OP_REG: begin
                            if (rd != 0) x[rd] <= alu;
                            pc <= pc + 4; state <= S_FETCH;
                        end
                        default: begin       // FENCE/SYSTEM: retire as NOP
                            pc <= pc + 4; state <= S_FETCH;
                        end
                    endcase
                end
                S_MEM: begin
                    if (bus_req && bus_ack) begin
                        bus_req <= 1'b0; bus_we <= 1'b0;
                        load_val <= ld_ext;
                        state <= (opc == OP_LD) ? S_WB : S_FETCH;
                        if (opc == OP_ST) pc <= pc + 4;
                    end
                end
                S_WB: begin
                    if (rd != 0) x[rd] <= load_val;
                    pc <= pc + 4; state <= S_FETCH;
                end
            endcase
        end
    end
endmodule
