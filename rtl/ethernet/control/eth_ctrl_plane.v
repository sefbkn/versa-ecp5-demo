// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright (c) 2026 Youssef Boukenken

// Ethernet control-plane MDIO launcher (sys_clk domain).
//
// The SoC-side interface remains 32 bits wide, but the active payload is just
// the packed 28-bit MDIO executor request in ctrl_req_data[27:0].
module eth_ctrl_plane (
    input  wire        clk,
    input  wire        rst,

    input  wire        ctrl_req_valid,
    output wire        ctrl_req_ready,
    input  wire [31:0] ctrl_req_data,
    output reg         ctrl_rsp_valid,
    output reg  [31:0] ctrl_rsp_data,

    output reg         mdio_req_valid,
    output reg  [27:0] mdio_req_data,
    input  wire        mdio_req_ready,
    input  wire        mdio_rsp_valid,
    input  wire [16:0] mdio_rsp_data
);

    reg       ctrl_cmd_busy;
    reg       ctrl_mdio_launch_pending;

    assign ctrl_req_ready = !ctrl_cmd_busy;

    always @(posedge clk) begin
        if (rst) begin
            ctrl_rsp_valid <= 1'b0;
            ctrl_rsp_data <= 32'd0;
            ctrl_cmd_busy <= 1'b0;
            ctrl_mdio_launch_pending <= 1'b0;

            mdio_req_valid <= 1'b0;
            mdio_req_data <= 28'd0;
        end else begin
            ctrl_rsp_valid <= 1'b0;
            mdio_req_valid <= 1'b0;

            if (ctrl_mdio_launch_pending && mdio_req_ready) begin
                mdio_req_valid <= 1'b1;
                ctrl_mdio_launch_pending <= 1'b0;
            end

            if (mdio_rsp_valid && ctrl_cmd_busy) begin
                ctrl_rsp_valid <= 1'b1;
                ctrl_rsp_data <= {mdio_rsp_data[16], 15'd0, mdio_rsp_data[15:0]};
                ctrl_cmd_busy <= 1'b0;
            end

            if (!ctrl_cmd_busy && ctrl_req_valid) begin
                mdio_req_data <= ctrl_req_data[27:0];
                ctrl_mdio_launch_pending <= 1'b1;
                ctrl_cmd_busy <= 1'b1;
            end
        end
    end

endmodule
