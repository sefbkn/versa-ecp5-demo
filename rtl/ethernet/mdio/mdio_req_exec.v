// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright (c) 2026 Youssef Boukenken

// MDIO request executor in sys_clk domain.
//
// Request format:
//   [27]    write
//   [26]    phy_sel (0=phy1, 1=phy2)
//   [25:21] page
//   [20:16] reg_addr
//   [15:0]  wdata
//
// Response format:
//   [16]    error
//   [15:0]  rdata

module mdio_req_exec #(
    parameter integer TIMEOUT_CYCLES = 32'd83333333 // ~0.83s @ 100MHz sys_clk
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        req_valid,
    input  wire [27:0] req_data,
    output wire        req_ready,
    output reg         rsp_valid,
    output reg  [16:0] rsp_data,

    output reg         phy1_cmd_valid,
    input  wire        phy1_cmd_ready,
    output reg  [26:0] phy1_cmd_data,
    input  wire [15:0] phy1_cmd_rdata,
    input  wire        phy1_cmd_done,

    output reg         phy2_cmd_valid,
    input  wire        phy2_cmd_ready,
    output reg  [26:0] phy2_cmd_data,
    input  wire [15:0] phy2_cmd_rdata,
    input  wire        phy2_cmd_done
);

    localparam [1:0]
        S_IDLE       = 2'd0,
        S_WAIT_READY = 2'd1,
        S_WAIT_DONE  = 2'd2;

    reg [1:0]  state;
    reg        active_phy_sel;
    reg [31:0] timeout_ctr;

    assign req_ready = !rst && (state == S_IDLE);

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            active_phy_sel <= 1'b0;
            timeout_ctr <= 32'd0;

            rsp_valid <= 1'b0;
            rsp_data <= 17'd0;

            phy1_cmd_valid <= 1'b0;
            phy1_cmd_data <= 27'd0;

            phy2_cmd_valid <= 1'b0;
            phy2_cmd_data <= 27'd0;
        end else begin
            rsp_valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    timeout_ctr <= 32'd0;
                    phy1_cmd_valid <= 1'b0;
                    phy2_cmd_valid <= 1'b0;

                    if (req_valid) begin
                        active_phy_sel <= req_data[26];

                        if (req_data[26]) begin
                            phy2_cmd_data <= {
                                req_data[27],
                                req_data[25:21],
                                req_data[20:16],
                                req_data[15:0]
                            };
                            phy2_cmd_valid <= 1'b1;
                        end else begin
                            phy1_cmd_data <= {
                                req_data[27],
                                req_data[25:21],
                                req_data[20:16],
                                req_data[15:0]
                            };
                            phy1_cmd_valid <= 1'b1;
                        end

                        state <= S_WAIT_READY;
                    end
                end

                S_WAIT_READY: begin
                    timeout_ctr <= timeout_ctr + 32'd1;

                    if (!active_phy_sel && phy1_cmd_valid && phy1_cmd_ready) begin
                        phy1_cmd_valid <= 1'b0;
                        timeout_ctr <= 32'd0;
                        state <= S_WAIT_DONE;
                    end else if (active_phy_sel && phy2_cmd_valid && phy2_cmd_ready) begin
                        phy2_cmd_valid <= 1'b0;
                        timeout_ctr <= 32'd0;
                        state <= S_WAIT_DONE;
                    end else if (timeout_ctr == TIMEOUT_CYCLES) begin
                        phy1_cmd_valid <= 1'b0;
                        phy2_cmd_valid <= 1'b0;
                        rsp_valid <= 1'b1;
                        rsp_data <= {1'b1, 16'd0};
                        state <= S_IDLE;
                    end
                end

                S_WAIT_DONE: begin
                    timeout_ctr <= timeout_ctr + 32'd1;

                    if (!active_phy_sel && phy1_cmd_done) begin
                        rsp_valid <= 1'b1;
                        rsp_data <= {1'b0, phy1_cmd_rdata};
                        state <= S_IDLE;
                    end else if (active_phy_sel && phy2_cmd_done) begin
                        rsp_valid <= 1'b1;
                        rsp_data <= {1'b0, phy2_cmd_rdata};
                        state <= S_IDLE;
                    end else if (timeout_ctr == TIMEOUT_CYCLES) begin
                        rsp_valid <= 1'b1;
                        rsp_data <= {1'b1, 16'd0};
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
