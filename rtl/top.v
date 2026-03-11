// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright (c) 2026 Youssef Boukenken

module versa_demo_top #(
    parameter PORT_MODE_SGMII = 1'b1
) (
    // 100MHz board oscillator (LVDS)
    input  wire        clk100_p,

    // PHY 1 management
    output wire        phy1_resetn,
    output wire        phy1_mdc,
    inout  wire        phy1_mdio,

    // PHY 1 RGMII
    input  wire        phy1_rxclk,
    input  wire [3:0]  phy1_rxd,
    input  wire        phy1_rxctrl,
    output wire        phy1_txclk,
    output wire [3:0]  phy1_txd,
    output wire        phy1_txctrl,

    // PHY 2 management
    output wire        phy2_resetn,
    output wire        phy2_mdc,
    inout  wire        phy2_mdio,

    // PHY 2 RGMII
    input  wire        phy2_rxclk,
    input  wire [3:0]  phy2_rxd,
    input  wire        phy2_rxctrl,
    output wire        phy2_txclk,
    output wire [3:0]  phy2_txd,
    output wire        phy2_txctrl,

    // SERDES reference clock control (ispClock5406D)
    output wire        refclk_en,
    output wire        refclk_rst_n,

    // UART
    output wire        uart_txd,
    input  wire        uart_rxd,

    // LEDs (active low)
    output wire [7:0]  led
);

    // 100MHz system clock input (LVDS -> single-ended)
    wire sys_clk;
    IB u_clk100_ib (
        .I  (clk100_p),
        .O  (sys_clk)
    );

    // Board-level clock-generator control straps (off-chip use only).
    // These are not consumed by internal RTL, they drive ispClock5406D pins.
    assign refclk_en    = PORT_MODE_SGMII;
    assign refclk_rst_n = PORT_MODE_SGMII;

    // Control SoC <-> Ethernet control-plane channel (sys_clk domain)
    wire        eth_ctrl_req_valid;
    wire        eth_ctrl_req_ready;
    wire [31:0] eth_ctrl_req_data;
    wire        eth_ctrl_rsp_valid;
    wire [31:0] eth_ctrl_rsp_data;
    wire        sys_rst;

    ethernet_top #(
        .PORT_MODE_SGMII(PORT_MODE_SGMII)
    ) u_ethernet_top (
        .sys_clk       (sys_clk),
        .sys_rst       (sys_rst),
        .ctrl_req_valid(eth_ctrl_req_valid),
        .ctrl_req_ready(eth_ctrl_req_ready),
        .ctrl_req_data (eth_ctrl_req_data),
        .ctrl_rsp_valid(eth_ctrl_rsp_valid),
        .ctrl_rsp_data (eth_ctrl_rsp_data),

        .phy1_resetn        (phy1_resetn),
        .phy1_mdc           (phy1_mdc),
        .phy1_mdio          (phy1_mdio),
        .phy1_rxclk         (phy1_rxclk),
        .phy1_rxd           (phy1_rxd),
        .phy1_rxctrl        (phy1_rxctrl),
        .phy1_txclk         (phy1_txclk),
        .phy1_txd           (phy1_txd),
        .phy1_txctrl        (phy1_txctrl),

        .phy2_resetn        (phy2_resetn),
        .phy2_mdc           (phy2_mdc),
        .phy2_mdio          (phy2_mdio),
        .phy2_rxclk         (phy2_rxclk),
        .phy2_rxd           (phy2_rxd),
        .phy2_rxctrl        (phy2_rxctrl),
        .phy2_txclk         (phy2_txclk),
        .phy2_txd           (phy2_txd),
        .phy2_txctrl        (phy2_txctrl)
    );

    control_soc #(
        .INIT_FILE("build/firmware/firmware.hex")
    ) u_control_soc (
        .clk          (sys_clk),
        .rst          (sys_rst),
        .uart_rx_pin  (uart_rxd),
        .uart_tx_pin  (uart_txd),
        .ctrl_req_valid(eth_ctrl_req_valid),
        .ctrl_req_ready(eth_ctrl_req_ready),
        .ctrl_req_data (eth_ctrl_req_data),
        .ctrl_rsp_valid(eth_ctrl_rsp_valid),
        .ctrl_rsp_data (eth_ctrl_rsp_data)
    );

    led_blinkshow u_led_blinkshow (
        .clk (sys_clk),
        .led (led)
    );

endmodule
