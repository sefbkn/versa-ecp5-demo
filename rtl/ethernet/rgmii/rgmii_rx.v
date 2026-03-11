// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright (c) 2026 Youssef Boukenken

// RGMII RX frame parser.
//
// Consumes raw recovered bytes plus RX_DV/RX_ER information and emits the
// payload-only frame stream used by the common FIFO contract. Frames flagged
// with RX_ER are discarded by suppressing output until RX_DV drops.

module rgmii_rx #(
    parameter STRIP_PREAMBLE = 1
) (
    input  wire        rx_clk,
    input  wire        rx_rst,
    input  wire [7:0]  rx_data,
    input  wire        rx_valid,
    input  wire        rx_error,

    output reg  [7:0]  frame_rx_data,
    output reg         frame_rx_valid,
    output reg         frame_rx_last
);

    reg       rx_drop_frame;
    reg       rx_sfd_seen;
    reg [7:0] rx_hold_data;
    reg       rx_hold_valid;

    always @(posedge rx_clk) begin
        if (rx_rst) begin
            rx_drop_frame  <= 1'b0;
            rx_sfd_seen    <= 1'b0;
            rx_hold_data   <= 8'd0;
            rx_hold_valid  <= 1'b0;
            frame_rx_data  <= 8'd0;
            frame_rx_valid <= 1'b0;
            frame_rx_last  <= 1'b0;
        end else begin
            frame_rx_valid <= 1'b0;
            frame_rx_last  <= 1'b0;

            if (rx_error || rx_drop_frame) begin
                rx_drop_frame <= 1'b1;
                rx_hold_valid <= 1'b0;
                if (!rx_valid) begin
                    rx_drop_frame <= 1'b0;
                    rx_sfd_seen   <= 1'b0;
                end
            end else if (!rx_valid) begin
                if (((!STRIP_PREAMBLE) || rx_sfd_seen) && rx_hold_valid) begin
                    frame_rx_data  <= rx_hold_data;
                    frame_rx_valid <= 1'b1;
                    frame_rx_last  <= 1'b1;
                end

                rx_sfd_seen   <= 1'b0;
                rx_hold_valid <= 1'b0;
            end else if (STRIP_PREAMBLE && !rx_sfd_seen) begin
                // Accept any valid Ethernet preamble length and start the
                // payload stream once the SFD byte becomes visible.
                if (rx_data == 8'hD5)
                    rx_sfd_seen <= 1'b1;
            end else begin
                if (rx_hold_valid) begin
                    frame_rx_data  <= rx_hold_data;
                    frame_rx_valid <= 1'b1;
                end

                rx_hold_data   <= rx_data;
                rx_hold_valid  <= 1'b1;
                rx_sfd_seen    <= 1'b1;
            end
        end
    end

endmodule
