// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright (c) 2026 Youssef Boukenken

// Ethernet management/control subsystem.
//
// Owns:
// - sys_clk-domain POR generation
// - Per-PHY init and MDIO masters
// - Control-plane MDIO launch/response handling
//
// Exposes:
// - Control-plane request/response interface (sys_clk domain)
// - Per-PHY management pins
// - both_phys_ready status

module eth_mgmt #(
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

    // PHY 2 management
    output wire        phy2_resetn,
    output wire        phy2_mdc,
    inout  wire        phy2_mdio,

    // Status (sys_clk domain)
    output wire        both_phys_ready
);

    // Power-on reset in sys_clk domain.
    reg [15:0] por_sr = 16'd0;
    assign sys_rst = !por_sr[15];
    always @(posedge sys_clk)
        por_sr <= {por_sr[14:0], 1'b1};

    wire phy1_init_done;
    wire phy2_init_done;

    wire        phy1_ext_cmd_valid;
    wire        phy1_ext_cmd_ready;
    wire [26:0] phy1_ext_cmd_data;
    wire [15:0] phy1_ext_cmd_rdata;
    wire        phy1_ext_cmd_done;

    wire        phy2_ext_cmd_valid;
    wire        phy2_ext_cmd_ready;
    wire [26:0] phy2_ext_cmd_data;
    wire [15:0] phy2_ext_cmd_rdata;
    wire        phy2_ext_cmd_done;

    phy_init #(
        .PHY_ADDR        (5'd0),
        .ENABLE_MODE_INIT(1),
        .MODE_SGMII      (PORT_MODE_SGMII)
    ) u_phy1_init (
        .clk           (sys_clk),
        .rst           (sys_rst),
        .phy_resetn    (phy1_resetn),
        .mdc           (phy1_mdc),
        .mdio          (phy1_mdio),
        .init_done     (phy1_init_done),
        .ext_cmd_valid (phy1_ext_cmd_valid),
        .ext_cmd_ready (phy1_ext_cmd_ready),
        .ext_cmd_data  (phy1_ext_cmd_data),
        .ext_cmd_rdata (phy1_ext_cmd_rdata),
        .ext_cmd_done  (phy1_ext_cmd_done)
    );

    phy_init #(
        .PHY_ADDR        (5'd0),
        .ENABLE_MODE_INIT(1),
        .MODE_SGMII      (PORT_MODE_SGMII)
    ) u_phy2_init (
        .clk           (sys_clk),
        .rst           (sys_rst),
        .phy_resetn    (phy2_resetn),
        .mdc           (phy2_mdc),
        .mdio          (phy2_mdio),
        .init_done     (phy2_init_done),
        .ext_cmd_valid (phy2_ext_cmd_valid),
        .ext_cmd_ready (phy2_ext_cmd_ready),
        .ext_cmd_data  (phy2_ext_cmd_data),
        .ext_cmd_rdata (phy2_ext_cmd_rdata),
        .ext_cmd_done  (phy2_ext_cmd_done)
    );

    wire        mdio_req_valid;
    wire [27:0] mdio_req_data;
    wire        mdio_req_ready;
    wire        mdio_rsp_valid;
    wire [16:0] mdio_rsp_data;

    mdio_req_exec u_mdio_req_exec (
        .clk           (sys_clk),
        .rst           (sys_rst),
        .req_valid     (mdio_req_valid),
        .req_data      (mdio_req_data),
        .req_ready     (mdio_req_ready),
        .rsp_valid     (mdio_rsp_valid),
        .rsp_data      (mdio_rsp_data),
        .phy1_cmd_valid(phy1_ext_cmd_valid),
        .phy1_cmd_ready(phy1_ext_cmd_ready),
        .phy1_cmd_data (phy1_ext_cmd_data),
        .phy1_cmd_rdata(phy1_ext_cmd_rdata),
        .phy1_cmd_done (phy1_ext_cmd_done),
        .phy2_cmd_valid(phy2_ext_cmd_valid),
        .phy2_cmd_ready(phy2_ext_cmd_ready),
        .phy2_cmd_data (phy2_ext_cmd_data),
        .phy2_cmd_rdata(phy2_ext_cmd_rdata),
        .phy2_cmd_done (phy2_ext_cmd_done)
    );

    assign both_phys_ready = phy1_init_done && phy2_init_done;

    eth_ctrl_plane u_eth_ctrl_plane (
        .clk                 (sys_clk),
        .rst                 (sys_rst),
        .ctrl_req_valid      (ctrl_req_valid),
        .ctrl_req_ready      (ctrl_req_ready),
        .ctrl_req_data       (ctrl_req_data),
        .ctrl_rsp_valid      (ctrl_rsp_valid),
        .ctrl_rsp_data       (ctrl_rsp_data),
        .mdio_req_valid      (mdio_req_valid),
        .mdio_req_data       (mdio_req_data),
        .mdio_req_ready      (mdio_req_ready),
        .mdio_rsp_valid      (mdio_rsp_valid),
        .mdio_rsp_data       (mdio_rsp_data)
    );

endmodule
