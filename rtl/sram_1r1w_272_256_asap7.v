// 1R1W register-file SRAM macro, 272b x 256. Density model = fakeram
// sram_1rw0r0w_272_256 (area 2923.876 um^2); RF macros in silicon are >=1R1W.
// Synthesis sees the stub (black box + .lib); `AURORA_SIM selects the model.
`ifdef AURORA_SIM
module sram_1r1w_272_256_asap7 (
    input          clk,
    input          r0_ce_in,
    input  [7:0]   r0_addr_in,
    output reg [271:0] r0_rd_out,
    input          w0_ce_in,
    input          w0_we_in,
    input  [7:0]   w0_addr_in,
    input  [271:0] w0_wd_in
);
    reg [271:0] mem [0:255];
    always @(posedge clk) begin
        if (r0_ce_in) r0_rd_out <= mem[r0_addr_in];
        if (w0_ce_in && w0_we_in) mem[w0_addr_in] <= w0_wd_in;
    end
endmodule
`else
(* black_box *)
module sram_1r1w_272_256_asap7 (
    input          clk,
    input          r0_ce_in,
    input  [7:0]   r0_addr_in,
    output [271:0] r0_rd_out,
    input          w0_ce_in,
    input          w0_we_in,
    input  [7:0]   w0_addr_in,
    input  [271:0] w0_wd_in
);
endmodule
`endif
