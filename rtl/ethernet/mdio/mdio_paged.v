// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright (c) 2026 Youssef Boukenken

// Paged MDIO wrapper for 88E1512-style register maps.
//
// Caller issues commands using logical {page, reg} addressing.
// This block always writes reg22 (page select) first, then performs
// the requested Clause-22 register access.

module mdio_paged #(
    parameter [4:0] PHY_ADDR = 5'd0
) (
    input  wire        clk,
    input  wire        rst,

    // Logical command interface
    // cmd_data = {write, page, reg_addr, wdata}
    input  wire        cmd_valid,
    output reg         cmd_ready,
    input  wire [26:0] cmd_data,
    output reg  [15:0] cmd_rdata,
    output reg         cmd_done,

    // MDIO pins
    output wire        mdc,
    inout  wire        mdio
);

    localparam [4:0] REG_PAGE_SELECT = 5'd22;

    localparam [2:0]
        S_IDLE      = 3'd0,
        S_PAGE_REQ  = 3'd1,
        S_PAGE_WAIT = 3'd2,
        S_CMD_REQ   = 3'd3,
        S_CMD_WAIT  = 3'd4;

    reg [2:0] state;

    reg [26:0] lat_cmd_data;

    reg        ll_cmd_valid;
    wire       ll_cmd_ready;
    reg        ll_cmd_write;
    reg [4:0]  ll_cmd_reg_addr;
    reg [15:0] ll_cmd_wdata;
    wire [15:0] ll_cmd_rdata;
    wire      ll_cmd_done;

    mdio_master u_mdio_master (
        .clk       (clk),
        .rst       (rst),
        .cmd_valid (ll_cmd_valid),
        .cmd_ready (ll_cmd_ready),
        .cmd_write (ll_cmd_write),
        .cmd_phyad (PHY_ADDR),
        .cmd_reg_addr (ll_cmd_reg_addr),
        .cmd_wdata (ll_cmd_wdata),
        .cmd_rdata (ll_cmd_rdata),
        .cmd_done  (ll_cmd_done),
        .mdc       (mdc),
        .mdio      (mdio)
    );

    always @(posedge clk) begin
        if (rst) begin
            state       <= S_IDLE;
            cmd_ready   <= 1'b1;
            cmd_done    <= 1'b0;
            cmd_rdata    <= 16'd0;
            lat_cmd_data <= 27'd0;
            ll_cmd_valid <= 1'b0;
            ll_cmd_write <= 1'b0;
            ll_cmd_reg_addr <= 5'd0;
            ll_cmd_wdata <= 16'd0;
        end else begin
            cmd_done <= 1'b0;

            case (state)
                S_IDLE: begin
                    cmd_ready <= 1'b1;
                    ll_cmd_valid <= 1'b0;
                    if (cmd_valid && cmd_ready) begin
                        cmd_ready <= 1'b0;
                        lat_cmd_data <= cmd_data;
                        state <= S_PAGE_REQ;
                    end
                end

                S_PAGE_REQ: begin
                    ll_cmd_valid <= 1'b1;
                    ll_cmd_write <= 1'b1;
                    ll_cmd_reg_addr <= REG_PAGE_SELECT;
                    ll_cmd_wdata <= {11'd0, lat_cmd_data[25:21]};
                    if (ll_cmd_valid && ll_cmd_ready) begin
                        ll_cmd_valid <= 1'b0;
                        state <= S_PAGE_WAIT;
                    end
                end

                S_PAGE_WAIT: begin
                    ll_cmd_valid <= 1'b0;
                    if (ll_cmd_done) begin
                        state <= S_CMD_REQ;
                    end
                end

                S_CMD_REQ: begin
                    ll_cmd_valid <= 1'b1;
                    ll_cmd_write <= lat_cmd_data[26];
                    ll_cmd_reg_addr <= lat_cmd_data[20:16];
                    ll_cmd_wdata <= lat_cmd_data[15:0];
                    if (ll_cmd_valid && ll_cmd_ready) begin
                        ll_cmd_valid <= 1'b0;
                        state <= S_CMD_WAIT;
                    end
                end

                S_CMD_WAIT: begin
                    ll_cmd_valid <= 1'b0;
                    if (ll_cmd_done) begin
                        cmd_rdata <= ll_cmd_rdata;
                        cmd_done <= 1'b1;
                        cmd_ready <= 1'b1;
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
