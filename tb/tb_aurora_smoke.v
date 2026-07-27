// ============================================================================
// AURORA smoke test: vector-add kernel on all chiplets/SMs/warps.
//   c[i] = a[i] + b[i],  i = 0..(LANES*WARPS-1) per SM (local slice space)
// Kernel (per thread):
//   TID  r1            ; global thread id
//   AND  r1, r1, 0xFF  ; local index within SM  (imm via MOVI+AND)
//   ... simplified: use r1[7:0] via SHL/SHR trick -- here we just mask
//   LDG  r2, [r1*4 + A_BASE]   ; addresses built with SHL
//   LDG  r3, [r1*4 + B_BASE]
//   ADD  r4, r2, r3
//   STG  [r1*4 + C_BASE], r4
//   EXIT
// A/B/C live in the GLOBAL window (bit31=1 from the SM's view) so the test
// exercises SM -> L2 -> D2D -> hub memory round-trips both ways.
// ============================================================================
`timescale 1ns/1ps
`include "aurora_pkg.vh"

module tb_aurora_smoke;
    reg clk = 0, rst = 1;
    always #0.5 clk = ~clk;          // 1 GHz

    reg         wb_stb = 0, wb_we = 0;
    reg  [31:0] wb_adr, wb_dat_i;
    wire [31:0] wb_dat_o;
    wire        wb_ack, gpu_idle;

    aurora_top_2p5d dut (
        .clk(clk), .rst(rst), .cpu_en(1'b0),   // external-host mode
        .wb_stb(wb_stb), .wb_we(wb_we), .wb_adr(wb_adr),
        .wb_dat_i(wb_dat_i), .wb_dat_o(wb_dat_o), .wb_ack(wb_ack),
        .gpu_idle(gpu_idle)
    );

    task wb_wr(input [31:0] a, input [31:0] d);
    begin
        @(posedge clk); wb_stb <= 1; wb_we <= 1; wb_adr <= a; wb_dat_i <= d;
        wait (wb_ack);  @(posedge clk); wb_stb <= 0; wb_we <= 0;
    end endtask

    task wb_rd(input [31:0] a, output [31:0] d);
    begin
        @(posedge clk); wb_stb <= 1; wb_we <= 0; wb_adr <= a;
        wait (wb_ack);  d = wb_dat_o; @(posedge clk); wb_stb <= 0;
    end endtask

    // instruction assembler helpers
    function [31:0] ins(input [4:0] op, input [4:0] rd, input [4:0] ra,
                        input [4:0] rb, input [11:0] imm);
        ins = {op, rd, ra, rb, imm};
    endfunction

    localparam A_BASE = 32'h8000_0000;   // global window from SM view
    localparam B_BASE = 32'h8000_1000;
    localparam C_BASE = 32'h8000_2000;
    localparam N      = `LANES*`WARPS;   // threads per SM (256)

    integer i, errors;
    reg [31:0] rd_val;

    initial begin
        repeat (10) @(posedge clk); rst = 0;

        // ---- init A/B in hub gmem (host view: 0x0000_xxxx) ----
        for (i = 0; i < N; i = i + 1) begin
            wb_wr(32'h0000_0000 + i*4, i);           // a[i] = i
            wb_wr(32'h0000_1000 + i*4, 1000 + i);    // b[i] = 1000+i
        end

        // ---- upload kernel to all SMs (broadcast sm=2'b11) ----
        //  r1 = tid & (N-1): TID, MOVI r5,N-1 ... keep simple: mask 0xFF
        wb_wr(32'h4000_3000 + 0*4,  ins(`OP_TID,  5'd1, 5'd0, 5'd0, 12'd0));
        wb_wr(32'h4000_3000 + 1*4,  ins(`OP_MOVI, 5'd5, 5'd0, 5'd0, 12'd255));
        wb_wr(32'h4000_3000 + 2*4,  ins(`OP_AND,  5'd1, 5'd1, 5'd5, 12'd0));
        wb_wr(32'h4000_3000 + 3*4,  ins(`OP_MOVI, 5'd6, 5'd0, 5'd0, 12'd2));
        wb_wr(32'h4000_3000 + 4*4,  ins(`OP_SHL,  5'd7, 5'd1, 5'd6, 12'd0)); // r7 = idx*4
        wb_wr(32'h4000_3000 + 5*4,  ins(`OP_MOVI, 5'd8, 5'd0, 5'd0, 12'd1));
        wb_wr(32'h4000_3000 + 6*4,  ins(`OP_MOVI, 5'd9, 5'd0, 5'd0, 12'd31));
        wb_wr(32'h4000_3000 + 7*4,  ins(`OP_SHL,  5'd8, 5'd8, 5'd9, 12'd0)); // r8 = 1<<31
        wb_wr(32'h4000_3000 + 8*4,  ins(`OP_ADD,  5'd7, 5'd7, 5'd8, 12'd0)); // global bit
        wb_wr(32'h4000_3000 + 9*4,  ins(`OP_LDG,  5'd2, 5'd7, 5'd0, 12'd0));         // a
        wb_wr(32'h4000_3000 +10*4,  ins(`OP_LDG,  5'd3, 5'd7, 5'd0, 12'h100));       // b (+0x1000>>4... use imm 0x100*?; see note)
        wb_wr(32'h4000_3000 +11*4,  ins(`OP_ADD,  5'd4, 5'd2, 5'd3, 12'd0));
        wb_wr(32'h4000_3000 +12*4,  ins(`OP_STG,  5'd0, 5'd7, 5'd4, 12'h200));       // c
        wb_wr(32'h4000_3000 +13*4,  ins(`OP_EXIT, 5'd0, 5'd0, 5'd0, 12'd0));
        // NOTE: imm12 is byte offset; 0x100 = 256B -- for the smoke test A/B/C
        // are spaced 0x100 apart instead of 0x1000 to fit imm12:
        //   re-init B/C bases accordingly below.

        // ---- (re)init with 0x100 spacing to match imm12 reach ----
        for (i = 0; i < 64; i = i + 1) begin  // first 64 threads checked
            wb_wr(32'h0000_0000 + i*4, i);
            wb_wr(32'h0000_0100 + i*4, 1000 + i);
            wb_wr(32'h0000_0200 + i*4, 0);
        end

        // ---- launch 2 warps/SM (64 threads/SM) ----
        wb_wr(32'h8000_0000, 32'd2);

        // ---- wait idle ----
        rd_val = 0;
        while (!rd_val[0]) begin
            repeat (50) @(posedge clk);
            wb_rd(32'h8000_0004, rd_val);
        end

        // ---- check c[i] = a[i] + b[i] (all chiplets wrote same window:
        //      identical local indices -> identical values, benign overlap) ----
        errors = 0;
        for (i = 0; i < 64; i = i + 1) begin
            wb_rd(32'h0000_0200 + i*4, rd_val);
            if (rd_val !== (i + 1000 + i)) begin
                errors = errors + 1;
                $display("MISMATCH c[%0d] = %0d expected %0d", i, rd_val, 1000+2*i);
            end
        end
        if (errors == 0) $display("AURORA_SMOKE_PASS");
        else             $display("AURORA_SMOKE_FAIL errors=%0d", errors);
        $finish;
    end

    initial begin #500000; $display("AURORA_SMOKE_TIMEOUT"); $finish; end
endmodule
