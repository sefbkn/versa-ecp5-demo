// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright (c) 2026 Youssef Boukenken

module mdio_mmio (
    input  wire        clk,
    input  wire        rst,
    input  wire [1:0]  bus_reg,
    input  wire [1:0]  read_reg,
    input  wire        bus_write,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,
    output reg         ctrl_req_valid,
    input  wire        ctrl_req_ready,
    output reg  [31:0] ctrl_req_data,
    input  wire        ctrl_rsp_valid,
    input  wire [31:0] ctrl_rsp_data
);

    localparam [1:0] REG_CTRL  = 2'b00;
    localparam [1:0] REG_WDATA = 2'b01;
    localparam [1:0] REG_RDATA = 2'b10;
    localparam [1:0] REG_STATE = 2'b11;

    reg       mdio_busy;
    reg       mdio_done;
    reg       mdio_error;
    reg       mdio_req_pending;
    reg       cmd_inflight;
    reg       mdio_cfg_write;
    reg       mdio_cfg_phy_sel;
    reg [4:0] mdio_cfg_page;
    reg [4:0] mdio_cfg_reg_addr;
    reg [15:0] mdio_cfg_wdata;
    reg [15:0] mdio_rdata_latched;

    wire can_launch_ctrl_req = !cmd_inflight && ctrl_req_ready;

    always @(posedge clk) begin
        if (rst) begin
            ctrl_req_valid <= 1'b0;
            ctrl_req_data <= 32'd0;
            mdio_busy <= 1'b0;
            mdio_done <= 1'b0;
            mdio_error <= 1'b0;
            mdio_req_pending <= 1'b0;
            cmd_inflight <= 1'b0;
            mdio_cfg_write <= 1'b0;
            mdio_cfg_phy_sel <= 1'b0;
            mdio_cfg_page <= 5'd0;
            mdio_cfg_reg_addr <= 5'd0;
            mdio_cfg_wdata <= 16'd0;
            mdio_rdata_latched <= 16'd0;
        end else begin
            ctrl_req_valid <= 1'b0;

            if (ctrl_rsp_valid && cmd_inflight) begin
                mdio_busy <= 1'b0;
                mdio_done <= 1'b1;
                mdio_error <= ctrl_rsp_data[31];
                mdio_rdata_latched <= ctrl_rsp_data[15:0];
                cmd_inflight <= 1'b0;
            end

            if (can_launch_ctrl_req && mdio_req_pending) begin
                ctrl_req_valid <= 1'b1;
                ctrl_req_data <= {
                    4'b0, // Reserved for future control-plane expansion.
                    mdio_cfg_write,
                    mdio_cfg_phy_sel,
                    mdio_cfg_page,
                    mdio_cfg_reg_addr,
                    mdio_cfg_wdata
                };
                mdio_req_pending <= 1'b0;
                mdio_busy <= 1'b1;
                cmd_inflight <= 1'b1;
            end

            if (bus_write && (bus_reg == REG_WDATA)) begin
                mdio_cfg_wdata <= wdata[15:0];
            end

            if (bus_write && (bus_reg == REG_CTRL)) begin
                mdio_cfg_write <= wdata[1];
                mdio_cfg_phy_sel <= wdata[2];
                mdio_cfg_reg_addr <= wdata[12:8];
                mdio_cfg_page <= wdata[17:13];

                if (wdata[0] && !mdio_busy && !mdio_req_pending) begin
                    mdio_req_pending <= 1'b1;
                    mdio_done <= 1'b0;
                    mdio_error <= 1'b0;
                end
            end
        end
    end

    always @(*) begin
        case (read_reg)
            REG_CTRL: rdata = {
                mdio_busy, mdio_done, mdio_error, 11'd0, mdio_cfg_page,
                mdio_cfg_reg_addr, 5'd0, mdio_cfg_phy_sel, mdio_cfg_write, 1'b0
            };
            REG_WDATA: rdata = {16'd0, mdio_cfg_wdata};
            REG_RDATA: rdata = {16'd0, mdio_rdata_latched};
            REG_STATE: rdata = {30'd0, mdio_req_pending, can_launch_ctrl_req};
            default: rdata = 32'd0;
        endcase
    end

endmodule
