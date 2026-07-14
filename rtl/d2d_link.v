// ============================================================================
// AURORA die-to-die link (2.5D interposer / F2F): request+response channel.
// 4:1 serialized, valid-qualified beats -- same discipline as the SenseEdge
// chiplet F2F study, parameterized width. One transaction in flight (GPU
// memory traffic is latency-tolerant through warp multithreading).
// TX packet: {we, addr[31:0], wdata[31:0]} = 65b -> 5 beats of 16b (msb pad).
// RX packet: rdata[31:0]                        -> 2 beats of 16b.
// ============================================================================
`include "aurora_pkg.vh"

module d2d_tx (
    input  wire        clk,
    input  wire        rst,
    // transaction side (from L2 slice remote port)
    input  wire        req,
    input  wire        we,
    input  wire [31:0] addr,
    input  wire [31:0] wdata,
    output reg         ack,
    output reg  [31:0] rdata,
    // physical die-to-die pins (16b each way)
    output reg  [15:0] tx_d,
    output reg         tx_v,
    input  wire [15:0] rx_d,
    input  wire        rx_v
);
    reg [2:0]  tx_beat;
    reg [79:0] tx_sh;                 // 65b payload left-aligned in 80b
    reg        sending, waiting;
    reg        rx_beat;
    reg [15:0] rx_hi;

    always @(posedge clk) begin
        if (rst) begin
            tx_v <= 0; ack <= 0; sending <= 0; waiting <= 0;
            tx_beat <= 0; rx_beat <= 0;
        end else begin
            ack <= 1'b0;
            // accept new transaction
            if (req && !sending && !waiting && !ack) begin
                tx_sh   <= {15'b0, we, addr, wdata};
                sending <= 1'b1;
                tx_beat <= 0;
            end
            // send 5 beats
            if (sending) begin
                tx_v  <= 1'b1;
                tx_d  <= tx_sh[79:64];
                tx_sh <= {tx_sh[63:0], 16'b0};
                tx_beat <= tx_beat + 1;
                if (tx_beat == 3'd4) begin
                    sending <= 1'b0;
                    waiting <= 1'b1;
                end
            end else
                tx_v <= 1'b0;
            // receive 2-beat response
            if (waiting && rx_v) begin
                if (!rx_beat) begin
                    rx_hi   <= rx_d;
                    rx_beat <= 1'b1;
                end else begin
                    rdata   <= {rx_hi, rx_d};
                    ack     <= 1'b1;
                    waiting <= 1'b0;
                    rx_beat <= 1'b0;
                end
            end
        end
    end
endmodule

module d2d_rx (
    input  wire        clk,
    input  wire        rst,
    // physical pins
    input  wire [15:0] rx_d,
    input  wire        rx_v,
    output reg  [15:0] tx_d,
    output reg         tx_v,
    // transaction side (to hub memory system)
    output reg         req,
    output reg         we,
    output reg  [31:0] addr,
    output reg  [31:0] wdata,
    input  wire        ack,
    input  wire [31:0] rdata
);
    reg [2:0]  beat;
    reg [79:0] sh;
    reg        resp;
    reg        rbeat;
    reg [31:0] rsh;

    always @(posedge clk) begin
        if (rst) begin
            beat <= 0; req <= 0; tx_v <= 0; resp <= 0; rbeat <= 0;
        end else begin
            // collect 5 request beats
            if (rx_v && !req && !resp) begin
                sh   <= {sh[63:0], rx_d};
                beat <= beat + 1;
                if (beat == 3'd4) begin
                    // sh now holds beats 0..3; rx_d is beat 4
                    {we, addr, wdata} <= {sh[48:0], rx_d};
                    req  <= 1'b1;
                    beat <= 0;
                end
            end
            // memory system answered -> stream 2 response beats
            if (req && ack) begin
                req   <= 1'b0;
                resp  <= 1'b1;
                rsh   <= rdata;
                rbeat <= 1'b0;
            end
            if (resp) begin
                tx_v  <= 1'b1;
                tx_d  <= rsh[31:16];
                rsh   <= {rsh[15:0], 16'b0};
                rbeat <= rbeat + 1;
                if (rbeat) resp <= 1'b0;
            end else
                tx_v <= 1'b0;
        end
    end
endmodule
