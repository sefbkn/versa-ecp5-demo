// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright (c) 2026 Youssef Boukenken

// SGMII RX protocol parser (Clause 36 framing + config ordered sets).
//
// Converts DCU-decoded symbols into payload bytes for the common frame
// interface and emits config-word pulses for AN/link policy.

module sgmii_rx (
    input  wire        rx_clk,
    input  wire        rx_rst,
    input  wire [7:0]  rx_data,
    input  wire        rx_k,

    output reg  [7:0]  frame_rx_data,
    output reg         frame_rx_valid,
    output reg         frame_rx_last,
    output reg  [15:0] rx_config_reg,
    output reg         rx_config_new
);

    // Symbol constants
    localparam [7:0] K28_5 = 8'hBC;  // Comma
    localparam [7:0] K27_7 = 8'hFB;  // Start of packet /S/
    localparam [7:0] K29_7 = 8'hFD;  // End of packet /T/
    localparam [7:0] K30_7 = 8'hFE;  // Error propagation

    // D-codes for config indicators
    localparam [7:0] D21_5 = 8'hB5;  // /C1/ config indicator
    localparam [7:0] D2_2  = 8'h42;  // /C2/ config indicator

    localparam [2:0]
        RX_IDLE       = 3'd0,
        RX_WAIT_TYPE  = 3'd1,
        RX_CONFIG_LSB = 3'd2,
        RX_CONFIG_MSB = 3'd3,
        RX_FRAME      = 3'd4;

    reg [2:0] rx_state;
    reg       sfd_seen;
    reg [7:0] an_config_lsb;

    always @(posedge rx_clk) begin
        if (rx_rst) begin
            rx_state       <= RX_IDLE;
            sfd_seen       <= 1'b0;
            frame_rx_data  <= 8'd0;
            frame_rx_valid <= 1'b0;
            frame_rx_last  <= 1'b0;
            rx_config_reg  <= 16'd0;
            rx_config_new  <= 1'b0;
            an_config_lsb  <= 8'd0;
        end else begin
            frame_rx_valid <= 1'b0;
            frame_rx_last  <= 1'b0;
            rx_config_new  <= 1'b0;

            case (rx_state)
                RX_IDLE: begin
                    if (rx_k && rx_data == K28_5)
                        rx_state <= RX_WAIT_TYPE;
                    else if (rx_k && rx_data == K27_7)
                        rx_state <= RX_FRAME;
                end

                RX_WAIT_TYPE: begin
                    if (!rx_k) begin
                        if (rx_data == D21_5 || rx_data == D2_2)
                            rx_state <= RX_CONFIG_LSB;
                        else
                            rx_state <= RX_IDLE;
                    end else if (rx_k && rx_data == K28_5)
                        rx_state <= RX_WAIT_TYPE;
                    else if (rx_k && rx_data == K27_7)
                        rx_state <= RX_FRAME;
                    else
                        rx_state <= RX_IDLE;
                end

                RX_CONFIG_LSB: begin
                    if (!rx_k) begin
                        an_config_lsb <= rx_data;
                        rx_state <= RX_CONFIG_MSB;
                    end else begin
                        rx_state <= RX_IDLE;
                    end
                end

                RX_CONFIG_MSB: begin
                    if (!rx_k) begin
                        rx_config_reg <= {rx_data, an_config_lsb};
                        rx_config_new <= 1'b1;
                    end
                    rx_state <= RX_IDLE;
                end

                RX_FRAME: begin
                    if (rx_k) begin
                        if ((rx_data == K29_7 || rx_data == K30_7) && sfd_seen)
                            frame_rx_last <= 1'b1;
                        rx_state <= RX_IDLE;
                        sfd_seen <= 1'b0;
                    end else if (!sfd_seen) begin
                        if (rx_data == 8'hD5)
                            sfd_seen <= 1'b1;
                    end else begin
                        frame_rx_data  <= rx_data;
                        frame_rx_valid <= 1'b1;
                    end
                end

                default: rx_state <= RX_IDLE;
            endcase
        end
    end

endmodule
