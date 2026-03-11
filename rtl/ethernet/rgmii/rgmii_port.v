// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright (c) 2026 Youssef Boukenken

// Per-port RGMII datapath wrapper.
//
// Owns the pad-side DDR/delay plumbing and bridges the framed byte stream to
// the common async frame FIFO interface.

module rgmii_port #(
    parameter RX_DELAY         = 64,
    parameter TX_CLK_DELAY     = 0,
    parameter RX_STRIP_PREAMBLE = 1,
    parameter TX_INSERT_PREAMBLE = 1
) (
    input  wire        rx_clk,
    input  wire        rx_rst,
    input  wire        tx_clk,
    input  wire        tx_rst,

    input  wire [3:0]  rgmii_rxd,
    input  wire        rgmii_rxctrl,
    output wire [3:0]  rgmii_txd,
    output wire        rgmii_txctrl,
    output wire        rgmii_txclk,

    // FIFO write side (toward peer)
    output wire [7:0]  fifo_wr_data,
    output wire        fifo_wr_valid,
    output wire        fifo_wr_last,

    // FIFO read side (from peer)
    input  wire [7:0]  fifo_rd_data,
    input  wire        fifo_rd_valid,
    input  wire        fifo_rd_last,
    output wire        fifo_rd_ready
);

    // Raw RX byte recovery: DELAYG + IDDRX1F + a small pipeline.
    wire [3:0] rx_d_delayed;
    wire       rx_ctl_delayed;
    wire [3:0] rx_d_rise;
    wire [3:0] rx_d_fall;
    wire       rx_ctl_rise;
    wire       rx_ctl_fall;

    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : gen_rxd
            DELAYG #(
                .DEL_MODE  ("SCLK_CENTERED"),
                .DEL_VALUE (RX_DELAY)
            ) u_dly (
                .A (rgmii_rxd[i]),
                .Z (rx_d_delayed[i])
            );

            IDDRX1F u_ddr (
                .D    (rx_d_delayed[i]),
                .SCLK (rx_clk),
                .RST  (1'b0),
                .Q0   (rx_d_rise[i]),
                .Q1   (rx_d_fall[i])
            );
        end
    endgenerate

    DELAYG #(
        .DEL_MODE  ("SCLK_CENTERED"),
        .DEL_VALUE (RX_DELAY)
    ) u_rx_ctl_dly (
        .A (rgmii_rxctrl),
        .Z (rx_ctl_delayed)
    );

    IDDRX1F u_rx_ctl_ddr (
        .D    (rx_ctl_delayed),
        .SCLK (rx_clk),
        .RST  (1'b0),
        .Q0   (rx_ctl_rise),
        .Q1   (rx_ctl_fall)
    );

    reg [7:0] rx_pipe1_data;
    reg       rx_pipe1_valid;
    reg       rx_pipe1_error;
    reg [7:0] rx_byte;
    reg       rx_byte_valid;
    reg       rx_byte_error;

    always @(posedge rx_clk) begin
        if (rx_rst) begin
            rx_pipe1_data  <= 8'd0;
            rx_pipe1_valid <= 1'b0;
            rx_pipe1_error <= 1'b0;
            rx_byte        <= 8'd0;
            rx_byte_valid  <= 1'b0;
            rx_byte_error  <= 1'b0;
        end else begin
            rx_pipe1_data  <= {rx_d_fall, rx_d_rise};
            rx_pipe1_valid <= rx_ctl_rise;
            rx_pipe1_error <= rx_ctl_rise ^ rx_ctl_fall;

            rx_byte        <= rx_pipe1_data;
            rx_byte_valid  <= rx_pipe1_valid;
            rx_byte_error  <= rx_pipe1_error;
        end
    end

    rgmii_rx #(
        .STRIP_PREAMBLE (RX_STRIP_PREAMBLE)
    ) u_rx (
        .rx_clk         (rx_clk),
        .rx_rst         (rx_rst),
        .rx_data        (rx_byte),
        .rx_valid       (rx_byte_valid),
        .rx_error       (rx_byte_error),
        .frame_rx_data  (fifo_wr_data),
        .frame_rx_valid (fifo_wr_valid),
        .frame_rx_last  (fifo_wr_last)
    );

    wire [7:0] tx_raw_data;
    wire       tx_raw_valid;
    reg  [7:0] tx_launch_data;
    reg        tx_launch_valid;

    rgmii_tx #(
        .INSERT_PREAMBLE (TX_INSERT_PREAMBLE)
    ) u_tx (
        .tx_clk         (tx_clk),
        .tx_rst         (tx_rst),
        .frame_tx_data  (fifo_rd_data),
        .frame_tx_valid (fifo_rd_valid),
        .frame_tx_last  (fifo_rd_last),
        .frame_tx_ready (fifo_rd_ready),
        .tx_data        (tx_raw_data),
        .tx_valid       (tx_raw_valid)
    );

    always @(negedge tx_clk) begin
        if (tx_rst) begin
            tx_launch_data  <= 8'd0;
            tx_launch_valid <= 1'b0;
        end else begin
            tx_launch_data  <= tx_raw_data;
            tx_launch_valid <= tx_raw_valid;
        end
    end

    // Raw TX byte launch: ODDRX1F on the data/control lines plus a delayed
    // forwarded clock.
    generate
        for (i = 0; i < 4; i = i + 1) begin : gen_txd
            wire txd_oddr;

            ODDRX1F u_tx_ddr (
                .D0   (tx_launch_data[i]),
                .D1   (tx_launch_data[4 + i]),
                .SCLK (tx_clk),
                .RST  (1'b0),
                .Q    (txd_oddr)
            );

            DELAYG #(
                .DEL_MODE  ("SCLK_ALIGNED"),
                .DEL_VALUE (0)
            ) u_tx_dly (
                .A (txd_oddr),
                .Z (rgmii_txd[i])
            );
        end
    endgenerate

    wire txctrl_oddr;

    ODDRX1F u_tx_ctl_ddr (
        .D0   (tx_launch_valid),
        .D1   (tx_launch_valid),
        .SCLK (tx_clk),
        .RST  (1'b0),
        .Q    (txctrl_oddr)
    );

    DELAYG #(
        .DEL_MODE  ("SCLK_ALIGNED"),
        .DEL_VALUE (0)
    ) u_tx_ctl_dly (
        .A (txctrl_oddr),
        .Z (rgmii_txctrl)
    );

    wire tx_clk_ddr;

    ODDRX1F u_tx_clk_ddr (
        .D0   (1'b1),
        .D1   (1'b0),
        .SCLK (tx_clk),
        .RST  (1'b0),
        .Q    (tx_clk_ddr)
    );

    DELAYG #(
        .DEL_MODE  ("SCLK_ALIGNED"),
        .DEL_VALUE (TX_CLK_DELAY)
    ) u_tx_clk_dly (
        .A (tx_clk_ddr),
        .Z (rgmii_txclk)
    );

endmodule
