// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright (c) 2026 Youssef Boukenken

// Unified Ethernet dataplane wrapper.
//
// Port mode is fixed at build time for both ports:
//   - 1'b1: SGMII frontend
//   - 1'b0: RGMII frontend
//
// Dataplane is always store-and-forward passthrough:
//   port1 RX -> port2 TX, and port2 RX -> port1 TX.

module eth_dataplane #(
    parameter PORT_MODE_SGMII = 1'b1
) (
    input  wire        sys_clk,
    input  wire        sys_rst,
    input  wire        both_phys_ready,

    // RGMII PHY 1 pins
    input  wire        phy1_rxclk,
    input  wire [3:0]  phy1_rxd,
    input  wire        phy1_rxctrl,
    output wire [3:0]  phy1_txd,
    output wire        phy1_txctrl,
    output wire        phy1_txclk,

    // RGMII PHY 2 pins
    input  wire        phy2_rxclk,
    input  wire [3:0]  phy2_rxd,
    input  wire        phy2_rxctrl,
    output wire [3:0]  phy2_txd,
    output wire        phy2_txctrl,
    output wire        phy2_txclk
);

    localparam FIFO_PAYLOAD_SIZE = 2048;
    localparam FIFO_MAX_FRAMES = 32;

    // Per-port frontend abstraction
    wire [7:0] port1_wr_data;
    wire       port1_wr_valid;
    wire       port1_wr_last;
    wire [7:0] port1_rd_data;
    wire       port1_rd_valid;
    wire       port1_rd_last;
    wire       port1_rd_ready;
    wire       port1_wr_clk;
    wire       port1_rd_clk;
    wire       port1_wr_rst;
    wire       port1_rd_rst;

    wire [7:0] port2_wr_data;
    wire       port2_wr_valid;
    wire       port2_wr_last;
    wire [7:0] port2_rd_data;
    wire       port2_rd_valid;
    wire       port2_rd_last;
    wire       port2_rd_ready;
    wire       port2_wr_clk;
    wire       port2_rd_clk;
    wire       port2_wr_rst;
    wire       port2_rd_rst;

    generate
        if (PORT_MODE_SGMII) begin : g_sgmii_mode
            // Hold the DCU in reset briefly after sys_rst releases.
            localparam DCU_RST_BITS = 20;
            reg  [DCU_RST_BITS-1:0] dcu_rst_cnt = {DCU_RST_BITS{1'b0}};
            wire dcu_rst = !(&dcu_rst_cnt);
            always @(posedge sys_clk) begin
                if (sys_rst)
                    dcu_rst_cnt <= {DCU_RST_BITS{1'b0}};
                else if (dcu_rst)
                    dcu_rst_cnt <= dcu_rst_cnt + 1'b1;
            end

            // ECP5 DCU / SGMII SerDes wrapper
            wire       ch0_rx_pclk, ch0_tx_pclk;
            wire [7:0] ch0_rx_data;
            wire       ch0_rx_k;
            wire       ch0_rx_cv_err;
            wire       ch0_rx_rst;
            wire       ch0_tx_rst;
            wire [7:0] ch0_tx_data;
            wire       ch0_tx_k;
            wire       ch0_tx_disp;

            wire       ch1_rx_pclk, ch1_tx_pclk;
            wire [7:0] ch1_rx_data;
            wire       ch1_rx_k;
            wire       ch1_rx_cv_err;
            wire       ch1_rx_rst;
            wire       ch1_tx_rst;
            wire [7:0] ch1_tx_data;
            wire       ch1_tx_k;
            wire       ch1_tx_disp;

            sgmii_dcu u_dcu (
                .dcu_rst         (dcu_rst),
                .both_phys_ready (both_phys_ready),
                .ch0_rx_pclk     (ch0_rx_pclk),
                .ch0_tx_pclk     (ch0_tx_pclk),
                .ch0_rx_data     (ch0_rx_data),
                .ch0_rx_k        (ch0_rx_k),
                .ch0_rx_cv_err   (ch0_rx_cv_err),
                .ch0_tx_data     (ch0_tx_data),
                .ch0_tx_k        (ch0_tx_k),
                .ch0_tx_disp     (ch0_tx_disp),
                .ch0_rx_rst      (ch0_rx_rst),
                .ch0_tx_rst      (ch0_tx_rst),
                .ch1_rx_pclk     (ch1_rx_pclk),
                .ch1_tx_pclk     (ch1_tx_pclk),
                .ch1_rx_data     (ch1_rx_data),
                .ch1_rx_k        (ch1_rx_k),
                .ch1_rx_cv_err   (ch1_rx_cv_err),
                .ch1_tx_data     (ch1_tx_data),
                .ch1_tx_k        (ch1_tx_k),
                .ch1_tx_disp     (ch1_tx_disp),
                .ch1_rx_rst      (ch1_rx_rst),
                .ch1_tx_rst      (ch1_tx_rst)
            );

            assign port1_wr_clk = ch0_rx_pclk;
            assign port1_rd_clk = ch0_tx_pclk;
            assign port1_wr_rst = ch0_rx_rst;
            assign port1_rd_rst = ch0_tx_rst;

            assign port2_wr_clk = ch1_rx_pclk;
            assign port2_rd_clk = ch1_tx_pclk;
            assign port2_wr_rst = ch1_rx_rst;
            assign port2_rd_rst = ch1_tx_rst;

            sgmii_pcs u_port1_sgmii (
                .rx_clk         (ch0_rx_pclk),
                .rx_rst         (port1_wr_rst),
                .tx_clk         (ch0_tx_pclk),
                .tx_rst         (port1_rd_rst),
                .rx_data        (ch0_rx_data),
                .rx_k           (ch0_rx_k),
                .rx_cv_err      (ch0_rx_cv_err),
                .tx_data        (ch0_tx_data),
                .tx_k           (ch0_tx_k),
                .tx_disp        (ch0_tx_disp),
                .frame_rx_data  (port1_wr_data),
                .frame_rx_valid (port1_wr_valid),
                .frame_rx_last  (port1_wr_last),
                .frame_tx_data  (port1_rd_data),
                .frame_tx_valid (port1_rd_valid),
                .frame_tx_last  (port1_rd_last),
                .frame_tx_ready (port1_rd_ready)
            );

            sgmii_pcs u_port2_sgmii (
                .rx_clk         (ch1_rx_pclk),
                .rx_rst         (port2_wr_rst),
                .tx_clk         (ch1_tx_pclk),
                .tx_rst         (port2_rd_rst),
                .rx_data        (ch1_rx_data),
                .rx_k           (ch1_rx_k),
                .rx_cv_err      (ch1_rx_cv_err),
                .tx_data        (ch1_tx_data),
                .tx_k           (ch1_tx_k),
                .tx_disp        (ch1_tx_disp),
                .frame_rx_data  (port2_wr_data),
                .frame_rx_valid (port2_wr_valid),
                .frame_rx_last  (port2_wr_last),
                .frame_tx_data  (port2_rd_data),
                .frame_tx_valid (port2_rd_valid),
                .frame_tx_last  (port2_rd_last),
                .frame_tx_ready (port2_rd_ready)
            );

            // Drive RGMII board pins low in SGMII mode.
            assign phy1_txd    = 4'd0;
            assign phy1_txctrl = 1'b0;
            assign phy1_txclk  = 1'b0;
            assign phy2_txd    = 4'd0;
            assign phy2_txctrl = 1'b0;
            assign phy2_txclk  = 1'b0;
        end else begin : g_rgmii_mode
            wire port1_rgmii_rst;
            wire port2_rgmii_rst;

            sync_ff #(.RESET_VAL(1'b1)) u_port1_rgmii_rst_sync (
                .clk      (phy1_rxclk),
                .rst      (sys_rst),
                .in_level (1'b0),
                .out_level(port1_rgmii_rst)
            );

            sync_ff #(.RESET_VAL(1'b1)) u_port2_rgmii_rst_sync (
                .clk      (phy2_rxclk),
                .rst      (sys_rst),
                .in_level (1'b0),
                .out_level(port2_rgmii_rst)
            );

            assign port1_wr_clk = phy1_rxclk;
            assign port1_rd_clk = phy1_rxclk;
            assign port1_wr_rst = port1_rgmii_rst;
            assign port1_rd_rst = port1_rgmii_rst;

            assign port2_wr_clk = phy2_rxclk;
            assign port2_rd_clk = phy2_rxclk;
            assign port2_wr_rst = port2_rgmii_rst;
            assign port2_rd_rst = port2_rgmii_rst;

            rgmii_port #(
                .RX_DELAY          (64),
                .TX_CLK_DELAY      (0),
                .RX_STRIP_PREAMBLE (1),
                .TX_INSERT_PREAMBLE(1)
            ) u_port1_rgmii (
                .rx_clk           (phy1_rxclk),
                .rx_rst           (port1_wr_rst),
                .tx_clk           (phy1_rxclk),
                .tx_rst           (port1_rd_rst),
                .rgmii_rxd        (phy1_rxd),
                .rgmii_rxctrl     (phy1_rxctrl),
                .rgmii_txd        (phy1_txd),
                .rgmii_txctrl     (phy1_txctrl),
                .rgmii_txclk      (phy1_txclk),
                .fifo_wr_data     (port1_wr_data),
                .fifo_wr_valid    (port1_wr_valid),
                .fifo_wr_last     (port1_wr_last),
                .fifo_rd_data     (port1_rd_data),
                .fifo_rd_valid    (port1_rd_valid),
                .fifo_rd_last     (port1_rd_last),
                .fifo_rd_ready    (port1_rd_ready)
            );

            rgmii_port #(
                .RX_DELAY          (64),
                .TX_CLK_DELAY      (0),
                .RX_STRIP_PREAMBLE (1),
                .TX_INSERT_PREAMBLE(1)
            ) u_port2_rgmii (
                .rx_clk           (phy2_rxclk),
                .rx_rst           (port2_wr_rst),
                .tx_clk           (phy2_rxclk),
                .tx_rst           (port2_rd_rst),
                .rgmii_rxd        (phy2_rxd),
                .rgmii_rxctrl     (phy2_rxctrl),
                .rgmii_txd        (phy2_txd),
                .rgmii_txctrl     (phy2_txctrl),
                .rgmii_txclk      (phy2_txclk),
                .fifo_wr_data     (port2_wr_data),
                .fifo_wr_valid    (port2_wr_valid),
                .fifo_wr_last     (port2_wr_last),
                .fifo_rd_data     (port2_rd_data),
                .fifo_rd_valid    (port2_rd_valid),
                .fifo_rd_last     (port2_rd_last),
                .fifo_rd_ready    (port2_rd_ready)
            );
        end
    endgenerate

    // RX FCS filters: check FCS and drop bad frames before the FIFOs.
    wire [7:0] port1_fcs_data,  port2_fcs_data;
    wire       port1_fcs_valid, port2_fcs_valid;
    wire       port1_fcs_last,  port2_fcs_last;
    wire       port1_fcs_drop,  port2_fcs_drop;

    eth_fcs_filter u_port1_rx_fcs_filter (
        .clk      (port1_wr_clk),
        .rst      (port1_wr_rst),
        .data_in  (port1_wr_data),
        .valid_in (port1_wr_valid),
        .last_in  (port1_wr_last),
        .data_out (port1_fcs_data),
        .valid_out(port1_fcs_valid),
        .last_out (port1_fcs_last),
        .drop     (port1_fcs_drop)
    );

    eth_fcs_filter u_port2_rx_fcs_filter (
        .clk      (port2_wr_clk),
        .rst      (port2_wr_rst),
        .data_in  (port2_wr_data),
        .valid_in (port2_wr_valid),
        .last_in  (port2_wr_last),
        .data_out (port2_fcs_data),
        .valid_out(port2_fcs_valid),
        .last_out (port2_fcs_last),
        .drop     (port2_fcs_drop)
    );

    // Passthrough FIFOs: port1 -> port2 and port2 -> port1
    async_frame_fifo #(
        .PAYLOAD_SIZE(FIFO_PAYLOAD_SIZE),
        .MAX_FRAMES(FIFO_MAX_FRAMES)
    ) u_port1_to_port2_fifo (
        .wr_clk   (port1_wr_clk),
        .wr_rst   (port1_wr_rst),
        .wr_data  (port1_fcs_data),
        .wr_valid (port1_fcs_valid),
        .wr_last  (port1_fcs_last),
        .wr_drop  (port1_fcs_drop),
        .rd_clk   (port2_rd_clk),
        .rd_rst   (port2_rd_rst),
        .rd_data  (port2_rd_data),
        .rd_valid (port2_rd_valid),
        .rd_last  (port2_rd_last),
        .rd_ready (port2_rd_ready)
    );

    async_frame_fifo #(
        .PAYLOAD_SIZE(FIFO_PAYLOAD_SIZE),
        .MAX_FRAMES(FIFO_MAX_FRAMES)
    ) u_port2_to_port1_fifo (
        .wr_clk   (port2_wr_clk),
        .wr_rst   (port2_wr_rst),
        .wr_data  (port2_fcs_data),
        .wr_valid (port2_fcs_valid),
        .wr_last  (port2_fcs_last),
        .wr_drop  (port2_fcs_drop),
        .rd_clk   (port1_rd_clk),
        .rd_rst   (port1_rd_rst),
        .rd_data  (port1_rd_data),
        .rd_valid (port1_rd_valid),
        .rd_last  (port1_rd_last),
        .rd_ready (port1_rd_ready)
    );

endmodule
