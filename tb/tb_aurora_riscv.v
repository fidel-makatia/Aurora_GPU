// ============================================================================
// AURORA RISC-V SoC test: NO external host. The on-die RV32 command processor
// boots from firmware (fw/cmd_proc.hex), initializes gmem, uploads the
// vector-add kernel to all 16 SMs, launches 2 warps/SM, polls idle, verifies
// c[i] = a[i] + b[i] itself, and reports 0x600D0000 | errors to the result
// mmio. The testbench only releases reset and reads the verdict.
// ============================================================================
`timescale 1ns/1ps
`include "aurora_pkg.vh"

module tb_aurora_riscv;
    reg clk = 0, rst = 1;
    always #0.5 clk = ~clk;          // 1 GHz

    wire [31:0] wb_dat_o;
    wire        wb_ack, gpu_idle, fw_done;
    wire [31:0] fw_result;

    aurora_top_2p5d dut (
        .clk(clk), .rst(rst), .cpu_en(1'b1),     // self-boot mode
        .wb_stb(1'b0), .wb_we(1'b0), .wb_adr(32'b0),
        .wb_dat_i(32'b0), .wb_dat_o(wb_dat_o), .wb_ack(wb_ack),
        .gpu_idle(gpu_idle),
        .fw_done(fw_done), .fw_result(fw_result)
    );

    initial begin
        repeat (10) @(posedge clk); rst = 0;
        wait (fw_done);
        @(posedge clk);
        if (fw_result === 32'h600D_0000)
            $display("AURORA_RISCV_PASS");
        else
            $display("AURORA_RISCV_FAIL result=%08x (errors=%0d)",
                     fw_result, fw_result[15:0]);
        $finish;
    end

    initial begin #2000000; $display("AURORA_RISCV_TIMEOUT"); $finish; end
endmodule
