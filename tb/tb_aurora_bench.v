// ============================================================================
// AURORA benchmark suite -- cycle-accurate RTL performance measurement.
// Four kernels on the full 4+1-chiplet GPU (16 SMs / 4096 threads):
//   launch : empty kernel               -> launch + drain overhead
//   copy   : c[i] = a[i]                -> memory bandwidth (serialized LSU)
//   vecadd : c[i] = a[i] + b[i]         -> classic streaming mix
//   saxpy  : y[i] = 3*x[i] + y[i]       -> MAD + memory
//   mad512 : 512 dependent MADs/thread  -> compute throughput vs 1024 ops/cyc peak
// Cycle counter runs at the core clock: 1 cycle = 1 ns at the 1 GHz target,
// so bytes/cycle = GB/s and ops/cycle = GOPS directly.
// ============================================================================
`timescale 1ns/1ps
`include "aurora_pkg.vh"

module tb_aurora_bench;
    reg clk = 0, rst = 1;
    always #0.5 clk = ~clk;

    reg         wb_stb = 0, wb_we = 0;
    reg  [31:0] wb_adr, wb_dat_i;
    wire [31:0] wb_dat_o;
    wire        wb_ack, gpu_idle, fw_done;
    wire [31:0] fw_result;

    aurora_top_2p5d dut (
        .clk(clk), .rst(rst), .cpu_en(1'b0),
        .wb_stb(wb_stb), .wb_we(wb_we), .wb_adr(wb_adr),
        .wb_dat_i(wb_dat_i), .wb_dat_o(wb_dat_o), .wb_ack(wb_ack),
        .gpu_idle(gpu_idle), .fw_done(fw_done), .fw_result(fw_result)
    );

    integer cyc;
    always @(posedge clk) if (!rst) cyc <= cyc + 1; else cyc <= 0;

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

    function [31:0] ins(input [4:0] op, input [4:0] rd, input [4:0] ra,
                        input [4:0] rb, input [11:0] imm);
        ins = {op, rd, ra, rb, imm};
    endfunction

    integer ip;   // imem word pointer
    task k(input [31:0] w);
    begin wb_wr(32'h4000_3000 + ip*4, w); ip = ip + 1; end endtask

    // shared prologue: r7 = (1<<31) + (tid & 255)*4   (9 words, same as smoke)
    task prologue;
    begin
        ip = 0;
        k(ins(`OP_TID,  5'd1, 5'd0, 5'd0, 12'd0));
        k(ins(`OP_MOVI, 5'd5, 5'd0, 5'd0, 12'd255));
        k(ins(`OP_AND,  5'd1, 5'd1, 5'd5, 12'd0));
        k(ins(`OP_MOVI, 5'd6, 5'd0, 5'd0, 12'd2));
        k(ins(`OP_SHL,  5'd7, 5'd1, 5'd6, 12'd0));
        k(ins(`OP_MOVI, 5'd8, 5'd0, 5'd0, 12'd1));
        k(ins(`OP_MOVI, 5'd9, 5'd0, 5'd0, 12'd31));
        k(ins(`OP_SHL,  5'd8, 5'd8, 5'd9, 12'd0));
        k(ins(`OP_ADD,  5'd7, 5'd7, 5'd8, 12'd0));
    end endtask

    integer t0, cycles;
    reg [31:0] rv;
    task run_kernel(output integer c);
    begin
        t0 = cyc;
        wb_wr(32'h8000_0000, 32'd8);          // 8 warps/SM = 4096 threads
        rv = 0;
        while (!rv[0]) begin
            repeat (20) @(posedge clk);
            wb_rd(32'h8000_0004, rv);
        end
        c = cyc - t0;
    end endtask

    // regions are 0x100 apart = 64 words: init EXACTLY 64 entries (indices
    // >=64 would clobber the next region -- found the hard way)
    task init_data;
    begin : init
        integer i;
        for (i = 0; i < 64; i = i + 1) begin
            wb_wr(32'h0000_0000 + i*4, i);            // a
            wb_wr(32'h0000_0100 + i*4, 7000 + i);     // b / y
            wb_wr(32'h0000_0200 + i*4, 0);            // c
        end
    end endtask

    integer i, errors, total_threads, ops, bytes;
    reg [31:0] expect_mad;

    initial begin
        repeat (10) @(posedge clk); rst = 0;
        total_threads = `NUM_CCHIP * `SMS_PER_CHIP * `WARPS * `LANES;
        $display("BENCH_CONFIG SMs=%0d threads=%0d peak_ops_per_cyc=%0d",
                 `NUM_CCHIP*`SMS_PER_CHIP, total_threads,
                 `NUM_CCHIP*`SMS_PER_CHIP*`LANES*2);

        // ---- launch overhead: EXIT-only kernel ----
        ip = 0; k(ins(`OP_EXIT, 0, 0, 0, 0));
        run_kernel(cycles);
        $display("BENCH launch  cycles=%0d", cycles);

        // ---- copy ----
        init_data;
        prologue;
        k(ins(`OP_LDG,  5'd2, 5'd7, 5'd0, 12'h000));
        k(ins(`OP_STG,  5'd0, 5'd7, 5'd2, 12'h200));
        k(ins(`OP_EXIT, 0, 0, 0, 0));
        run_kernel(cycles);
        bytes = total_threads * 8;
        errors = 0;
        for (i = 0; i < 32; i = i + 1) begin
            wb_rd(32'h0000_0200 + i*4, rv);
            if (rv !== i) errors = errors + 1;
        end
        $display("BENCH copy    cycles=%0d bytes=%0d GBps=%0.2f errors=%0d",
                 cycles, bytes, $itor(bytes)/$itor(cycles), errors);

        // ---- vecadd ----
        init_data;
        prologue;
        k(ins(`OP_LDG,  5'd2, 5'd7, 5'd0, 12'h000));
        k(ins(`OP_LDG,  5'd3, 5'd7, 5'd0, 12'h100));
        k(ins(`OP_ADD,  5'd4, 5'd2, 5'd3, 12'd0));
        k(ins(`OP_STG,  5'd0, 5'd7, 5'd4, 12'h200));
        k(ins(`OP_EXIT, 0, 0, 0, 0));
        run_kernel(cycles);
        bytes = total_threads * 12;
        errors = 0;
        for (i = 0; i < 32; i = i + 1) begin
            wb_rd(32'h0000_0200 + i*4, rv);
            if (rv !== (7000 + 2*i)) errors = errors + 1;
        end
        $display("BENCH vecadd  cycles=%0d bytes=%0d GBps=%0.2f errors=%0d",
                 cycles, bytes, $itor(bytes)/$itor(cycles), errors);

        // ---- saxpy: y = 3*x + y ----
        init_data;
        prologue;
        k(ins(`OP_MOVI, 5'd9, 5'd0, 5'd0, 12'd3));
        k(ins(`OP_LDG,  5'd2, 5'd7, 5'd0, 12'h000));
        k(ins(`OP_LDG,  5'd3, 5'd7, 5'd0, 12'h100));
        k(ins(`OP_MAD,  5'd3, 5'd2, 5'd9, 12'd0));
        k(ins(`OP_STG,  5'd0, 5'd7, 5'd3, 12'h200));
        k(ins(`OP_EXIT, 0, 0, 0, 0));
        run_kernel(cycles);
        bytes = total_threads * 12;
        ops   = total_threads * 2;
        errors = 0;
        for (i = 0; i < 32; i = i + 1) begin
            wb_rd(32'h0000_0200 + i*4, rv);
            if (rv !== (3*i + 7000 + i)) errors = errors + 1;
        end
        $display("BENCH saxpy   cycles=%0d GBps=%0.2f GOPS=%0.2f errors=%0d",
                 cycles, $itor(bytes)/$itor(cycles),
                 $itor(ops)/$itor(cycles), errors);

        // ---- mad512: compute-bound, 512 dependent MADs (r3 = 3*r3) ----
        prologue;
        k(ins(`OP_MOVI, 5'd2, 5'd0, 5'd0, 12'd2));
        k(ins(`OP_MOVI, 5'd3, 5'd0, 5'd0, 12'd1));
        for (i = 0; i < 512; i = i + 1)
            k(ins(`OP_MAD, 5'd3, 5'd3, 5'd2, 12'd0));   // r3 = r3*2 + r3
        k(ins(`OP_STG,  5'd0, 5'd7, 5'd3, 12'h200));
        k(ins(`OP_EXIT, 0, 0, 0, 0));
        run_kernel(cycles);
        ops = total_threads * 512 * 2;
        expect_mad = 32'd1;
        for (i = 0; i < 512; i = i + 1) expect_mad = expect_mad * 3;
        wb_rd(32'h0000_0200, rv);
        $display("BENCH mad512  cycles=%0d GOPS=%0.2f peak_pct=%0.1f%% check=%s",
                 cycles, $itor(ops)/$itor(cycles),
                 100.0*$itor(ops)/$itor(cycles)/1024.0,
                 (rv === expect_mad) ? "PASS" : "FAIL");

        // ---- mad_nostore: pure compute (no store drain -- the mad512
        //      number is dominated by 4096 stores through the single-PC HBM)
        prologue;
        k(ins(`OP_MOVI, 5'd2, 5'd0, 5'd0, 12'd2));
        k(ins(`OP_MOVI, 5'd3, 5'd0, 5'd0, 12'd1));
        for (i = 0; i < 512; i = i + 1)
            k(ins(`OP_MAD, 5'd3, 5'd3, 5'd2, 12'd0));
        k(ins(`OP_EXIT, 0, 0, 0, 0));
        run_kernel(cycles);
        ops = total_threads * 512 * 2;
        $display("BENCH mad_pure cycles=%0d GOPS=%0.2f peak_pct=%0.1f%%",
                 cycles, $itor(ops)/$itor(cycles),
                 100.0*$itor(ops)/$itor(cycles)/1024.0);

        // ---- lds_burst: on-chip shared-memory bandwidth (256 LDS/thread)
        prologue;
        k(ins(`OP_STS,  5'd0, 5'd7, 5'd7, 12'd0));
        for (i = 0; i < 256; i = i + 1)
            k(ins(`OP_LDS, 5'd2, 5'd7, 5'd0, 12'd0));
        k(ins(`OP_EXIT, 0, 0, 0, 0));
        run_kernel(cycles);
        bytes = total_threads * 256 * 4;
        $display("BENCH lds     cycles=%0d GBps=%0.2f (on-chip)",
                 cycles, $itor(bytes)/$itor(cycles));

        $display("AURORA_BENCH_DONE");
        $finish;
    end

    initial begin #20000000; $display("AURORA_BENCH_TIMEOUT"); $finish; end
endmodule
