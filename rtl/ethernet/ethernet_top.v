// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright (c) 2026 Youssef Boukenken

// Ethernet subsystem top-level.
//
// Owns:
// - Ethernet management/control subsystem
// - Unified passthrough dataplane (eth_dataplane)

module ethernet_top #(
    parameter PORT_MODE_SGMII = 1'b1
) (
    input  wire        sys_clk,
    output wire        sys_rst,

    // Control plane (sys_clk domain)
    input  wire        ctrl_req_valid,
    output wire        ctrl_req_ready,
    input  wire [31:0] ctrl_req_data,
    output wire        ctrl_rsp_valid,
    output wire [31:0] ctrl_rsp_data,

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
    output wire        phy2_txctrl
);
    wire both_phys_ready;

    eth_mgmt #(
        .PORT_MODE_SGMII(PORT_MODE_SGMII)
    ) u_eth_mgmt (
        .sys_clk       (sys_clk),
        .sys_rst       (sys_rst),
        .ctrl_req_valid(ctrl_req_valid),
        .ctrl_req_ready(ctrl_req_ready),
        .ctrl_req_data (ctrl_req_data),
        .ctrl_rsp_valid(ctrl_rsp_valid),
        .ctrl_rsp_data (ctrl_rsp_data),
        .phy1_resetn   (phy1_resetn),
        .phy1_mdc      (phy1_mdc),
        .phy1_mdio     (phy1_mdio),
        .phy2_resetn   (phy2_resetn),
        .phy2_mdc      (phy2_mdc),
        .phy2_mdio     (phy2_mdio),
        .both_phys_ready(both_phys_ready)
    );

    // Unified ethernet dataplane.
    eth_dataplane #(
        .PORT_MODE_SGMII(PORT_MODE_SGMII)
    ) u_eth_dataplane (
        .sys_clk         (sys_clk),
        .sys_rst         (sys_rst),
        .both_phys_ready (both_phys_ready),
        .phy1_rxclk      (phy1_rxclk),
        .phy1_rxd        (phy1_rxd),
        .phy1_rxctrl     (phy1_rxctrl),
        .phy1_txd        (phy1_txd),
        .phy1_txctrl     (phy1_txctrl),
        .phy1_txclk      (phy1_txclk),
        .phy2_rxclk      (phy2_rxclk),
        .phy2_rxd        (phy2_rxd),
        .phy2_rxctrl     (phy2_rxctrl),
        .phy2_txd        (phy2_txd),
        .phy2_txctrl     (phy2_txctrl),
        .phy2_txclk      (phy2_txclk)
    );

endmodule
