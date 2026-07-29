// ============================================================================
// GLS bring-up test: firmware is loaded over the WISHBONE DEBUG PORT into the
// gate-level boot RAM ($readmemh cannot reach synthesized flops -- this is
// the real silicon bring-up path), then cpu_en is released and the RV32
// GATES boot, upload the kernel, launch, verify, and report.
// ============================================================================
`timescale 1ns/1ps
`include "aurora_pkg.vh"

module tb_aurora_riscv_gls;
    reg clk = 0, rst = 1, cpu_en = 0;
    always #0.5 clk = ~clk;

    reg         wb_stb = 0, wb_we = 0;
    reg  [31:0] wb_adr, wb_dat_i;
    wire [31:0] wb_dat_o;
    wire        wb_ack, gpu_idle, fw_done;
    wire [31:0] fw_result;

    aurora_top_2p5d dut (
        .clk(clk), .rst(rst), .cpu_en(cpu_en),
        .wb_stb(wb_stb), .wb_we(wb_we), .wb_adr(wb_adr),
        .wb_dat_i(wb_dat_i), .wb_dat_o(wb_dat_o), .wb_ack(wb_ack),
        .gpu_idle(gpu_idle), .fw_done(fw_done), .fw_result(fw_result)
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

    reg [31:0] fwimg [0:4095];
    integer i;
    initial begin
        $readmemh("fw/cmd_proc.hex", fwimg);
        repeat (10) @(posedge clk); rst = 0;
        for (i = 0; i < 4096; i = i + 1)
            if (^fwimg[i] !== 1'bx)
                wb_wr(32'hC000_0000 + i*4, fwimg[i]);
        $display("GLS: firmware loaded over WB debug port");
        cpu_en = 1;
        fork begin : dbg
            integer t;
            reg [31:0] st;
            for (t = 0; t < 40; t = t + 1) begin
                repeat (2000) @(posedge clk);
                wb_rd(32'h8000_0004, st);
                $display("GLS_DBG t=%0dk idle=%b gpu_idle=%b fw_done=%b",
                         (t+1)*2, st[0], gpu_idle, fw_done);
            end
        end join_none
        wait (fw_done); @(posedge clk);
        if (fw_result === 32'h600D_0000) $display("AURORA_GLS_HUB_PASS");
        else $display("AURORA_GLS_HUB_FAIL result=%08x", fw_result);
        $finish;
    end

    initial begin #8000000; $display("AURORA_GLS_HUB_TIMEOUT"); $finish; end
endmodule
