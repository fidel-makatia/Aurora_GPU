// ============================================================================
// AURORA IO/host chiplet ("hub" die):
//  - RV32IM host CPU (riscv_core): the on-die command processor. Boots from
//    boot RAM, uploads GPU kernels, launches, polls idle -- Aurora is a
//    self-contained SoC. Firmware: fw/cmd_proc.S (assembled by tools/rvasm.py).
//  - Wishbone host slave: bring-up/debug port (firmware load, gmem poke,
//    manual kernel launch -- the full v1 host map is preserved).
//  - command processor registers: broadcast imem writes + launch to compute
//    chiplets over sideband, aggregate idle status.
//  - global memory controller: round-robin over NUM_CCHIP D2D endpoints,
//    backed by an on-die scratch acting as the DRAM model boundary (a real
//    flagship replaces this bank with an HBM/LPDDR PHY + controller IP).
//
// CPU memory map                        | external Wishbone map (unchanged +C)
//   0x0000_0000  boot RAM (16 KB)       |   0x0000_0000  gmem window
//   0x1000_0000  gmem window            |   0x4000_0000  SM imem write
//   0x4000_0000  SM imem write          |   0x8000_0000  launch / 0004 status
//   0x8000_0000  launch / 0004 status   |   0xC000_0000  boot RAM (fw load)
//   0xF000_0000  result mmio (fw_done)  |
// ============================================================================
`include "aurora_pkg.vh"

module io_chiplet #(
    parameter GMEM_WORDS = 16384,
    parameter BOOT_WORDS = 4096
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        cpu_en,     // strap: 1 = RV32 self-boot, 0 = WB host only
    // Wishbone host (bring-up/debug)
    input  wire        wb_stb,
    input  wire        wb_we,
    input  wire [31:0] wb_adr,
    input  wire [31:0] wb_dat_i,
    output reg  [31:0] wb_dat_o,
    output reg         wb_ack,
    // firmware result mmio (sim/bring-up observation)
    output reg         fw_done,
    output reg  [31:0] fw_result,
    // sideband to compute chiplets
    output reg                     cc_launch,
    output reg [`WARP_ID_W:0]      cc_nwarps,
    output reg                     cc_imem_we,
    output reg [1:0]               cc_imem_sm,
    output reg [9:0]               cc_imem_waddr,
    output reg [31:0]              cc_imem_wdata,
    input  wire [`NUM_CCHIP-1:0]   cc_idle,
    // D2D physical pins, one endpoint per compute chiplet
    input  wire [`NUM_CCHIP*16-1:0] d2d_rx_d,
    input  wire [`NUM_CCHIP-1:0]    d2d_rx_v,
    output wire [`NUM_CCHIP*16-1:0] d2d_tx_d,
    output wire [`NUM_CCHIP-1:0]    d2d_tx_v
);
    // ---------------- global memory (DRAM-model boundary) ----------------
    reg [31:0] gmem [0:GMEM_WORDS-1];

    // ---------------- boot RAM (CPU code + data) ----------------
    reg [31:0] bootram [0:BOOT_WORDS-1];
`ifdef AURORA_SIM
`ifndef AURORA_FW_HEX
`define AURORA_FW_HEX "fw/cmd_proc.hex"
`endif
    initial $readmemh(`AURORA_FW_HEX, bootram);
`endif

    // ---------------- D2D endpoints ----------------
    wire [`NUM_CCHIP-1:0]  ep_req, ep_we;
    wire [`NUM_CCHIP*32-1:0] ep_addr, ep_wdata;
    reg  [`NUM_CCHIP-1:0]  ep_ack;
    reg  [31:0]            ep_rdata;

    genvar c;
    generate
        for (c = 0; c < `NUM_CCHIP; c = c + 1) begin : ep
            d2d_rx u_rx (
                .clk(clk), .rst(rst),
                .rx_d(d2d_rx_d[c*16 +: 16]), .rx_v(d2d_rx_v[c]),
                .tx_d(d2d_tx_d[c*16 +: 16]), .tx_v(d2d_tx_v[c]),
                .req(ep_req[c]), .we(ep_we[c]),
                .addr (ep_addr [c*32 +: 32]),
                .wdata(ep_wdata[c*32 +: 32]),
                .ack(ep_ack[c]), .rdata(ep_rdata)
            );
        end
    endgenerate

    // ---------------- memory controller: round-robin ----------------
    reg [1:0] mgrant;
    integer i;
    reg [1:0] mnxt; reg mfound;
    always @* begin
        mnxt = mgrant; mfound = 0;
        for (i = 1; i <= `NUM_CCHIP; i = i + 1)
            if (!mfound && ep_req[(mgrant + i) % `NUM_CCHIP]) begin
                mnxt = (mgrant + i) % `NUM_CCHIP; mfound = 1;
            end
    end

    wire [31:0] m_addr  = ep_addr [mgrant*32 +: 32];
    wire [31:0] m_wdata = ep_wdata[mgrant*32 +: 32];

    reg m_busy;
    always @(posedge clk) begin
        if (rst) begin
            mgrant <= 0; m_busy <= 0; ep_ack <= 0;
        end else begin
            ep_ack <= 0;
            if (!m_busy) begin
                if (mfound) begin mgrant <= mnxt; m_busy <= 1'b1; end
            end else begin
                if (ep_we[mgrant]) gmem[m_addr[15:2]] <= m_wdata;
                ep_rdata       <= gmem[m_addr[15:2]];
                ep_ack[mgrant] <= 1'b1;
                m_busy         <= 1'b0;
            end
        end
    end

    // ---------------- RV32 host CPU ----------------
    wire        cpu_req, cpu_we;
    wire [31:0] cpu_addr, cpu_wdata;
    wire [3:0]  cpu_be;
    reg         cpu_ack;
    reg  [31:0] cpu_rdata;

    riscv_core u_cpu (
        .clk(clk), .rst(rst | ~cpu_en),
        .bus_req(cpu_req), .bus_we(cpu_we),
        .bus_addr(cpu_addr), .bus_wdata(cpu_wdata), .bus_be(cpu_be),
        .bus_ack(cpu_ack), .bus_rdata(cpu_rdata)
    );

    // ------------- internal hub bus: WB (priority) + CPU arbiter -------------
    // One request is served per cycle; both masters use single-beat accesses.
    // CPU address nibble 1 (gmem) is remapped to hub nibble 0 so the CPU's
    // low addresses can hold its boot RAM.
    wire        cpu_hub    = cpu_req && (cpu_addr[31:28] != 4'h0)
                                     && (cpu_addr[31:28] != 4'hF);
    wire        hub_stb    = wb_stb || cpu_hub;
    wire        hub_from_wb= wb_stb;                 // WB wins ties
    wire        hub_we     = hub_from_wb ? wb_we    : cpu_we;
    wire [31:0] hub_adr_in = hub_from_wb ? wb_adr   : cpu_addr;
    wire [31:0] hub_dat    = hub_from_wb ? wb_dat_i : cpu_wdata;
    wire [3:0]  hub_nib    = (hub_adr_in[31:28] == 4'h1) ? 4'h0
                                                         : hub_adr_in[31:28];
    reg         hub_ack;
    reg  [31:0] hub_rdata;
    reg         hub_served_wb;

    always @(posedge clk) begin
        if (rst) begin
            hub_ack <= 0; cc_launch <= 0; cc_imem_we <= 0;
        end else begin
            hub_ack    <= 0;
            cc_launch  <= 0;
            cc_imem_we <= 0;
            if (hub_stb && !hub_ack) begin
                hub_ack       <= 1'b1;
                hub_served_wb <= hub_from_wb;
                case (hub_nib)
                    4'h0: begin
                        if (hub_we) gmem[hub_adr_in[15:2]] <= hub_dat;
                        hub_rdata <= gmem[hub_adr_in[15:2]];
                    end
                    4'h4: begin
                        cc_imem_we    <= hub_we;
                        cc_imem_sm    <= hub_adr_in[13:12];
                        cc_imem_waddr <= hub_adr_in[11:2];
                        cc_imem_wdata <= hub_dat;
                    end
                    4'h8: begin
                        if (hub_adr_in[3:0] == 4'h0 && hub_we) begin
                            cc_launch <= 1'b1;
                            cc_nwarps <= hub_dat[`WARP_ID_W:0];
                        end else
                            hub_rdata <= {31'b0, &cc_idle};
                    end
                    4'hC: begin                       // boot RAM (fw load)
                        if (hub_we) bootram[hub_adr_in[13:2]] <= hub_dat;
                        hub_rdata <= bootram[hub_adr_in[13:2]];
                    end
                    default: hub_rdata <= 32'hDEAD_BEEF;
                endcase
            end
        end
    end

    always @* begin
        wb_ack   = hub_ack && hub_served_wb;
        wb_dat_o = hub_rdata;
    end

    // ------------- CPU-private slaves: boot RAM + result mmio -------------
    // The hub-side ack reaches the CPU combinationally (hub_ack is a single
    // registered pulse); a registered re-ack here would let the hub serve the
    // still-pending request twice -- a double `launch` fire.
    wire cpu_boot = cpu_req && (cpu_addr[31:28] == 4'h0);
    wire cpu_mmio = cpu_req && (cpu_addr[31:28] == 4'hF);

    reg        cpu_ack_r;
    reg [31:0] cpu_rdata_r;
    wire       cpu_hub_ack = hub_ack && !hub_served_wb;

    always @(posedge clk) begin
        if (rst) begin
            cpu_ack_r <= 0; fw_done <= 0; fw_result <= 0;
        end else begin
            cpu_ack_r <= 0;
            if (cpu_boot && !cpu_ack_r) begin
                if (cpu_we) begin
                    if (cpu_be[0]) bootram[cpu_addr[13:2]][7:0]   <= cpu_wdata[7:0];
                    if (cpu_be[1]) bootram[cpu_addr[13:2]][15:8]  <= cpu_wdata[15:8];
                    if (cpu_be[2]) bootram[cpu_addr[13:2]][23:16] <= cpu_wdata[23:16];
                    if (cpu_be[3]) bootram[cpu_addr[13:2]][31:24] <= cpu_wdata[31:24];
                end
                cpu_rdata_r <= bootram[cpu_addr[13:2]];
                cpu_ack_r   <= 1'b1;
            end else if (cpu_mmio && !cpu_ack_r) begin
                if (cpu_we) begin
                    fw_done   <= 1'b1;
                    fw_result <= cpu_wdata;
`ifdef AURORA_SIM
                    $display("FW_RESULT %08x", cpu_wdata);
`endif
                end
                cpu_rdata_r <= fw_result;
                cpu_ack_r   <= 1'b1;
            end
        end
    end

    always @* begin
        cpu_ack   = cpu_ack_r || cpu_hub_ack;
        cpu_rdata = cpu_hub_ack ? hub_rdata : cpu_rdata_r;
    end
endmodule
