// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright (c) 2026 Youssef Boukenken

// SGMII PCS wrapper.
//
// Integrates dedicated RX / AN / TX blocks behind one PCS interface.

(* keep_hierarchy = "yes" *)
module sgmii_pcs (
    input  wire        rx_clk,
    input  wire        rx_rst,
    input  wire        tx_clk,
    input  wire        tx_rst,

    // Decoded RX input (rx_clk domain). Single symbol from DCU
    input  wire [7:0]  rx_data,
    input  wire        rx_k,
    input  wire        rx_cv_err,

    // TX output (tx_clk domain). Single symbol to DCU
    output wire [7:0]  tx_data,
    output wire        tx_k,
    output wire        tx_disp,

    // Frame RX output (rx_clk domain)
    output wire [7:0]  frame_rx_data,
    output wire        frame_rx_valid,
    output wire        frame_rx_last,

    // Frame TX input (tx_clk domain)
    input  wire [7:0]  frame_tx_data,
    input  wire        frame_tx_valid,
    input  wire        frame_tx_last,

    // Frame TX flow control (tx_clk domain)
    output wire        frame_tx_ready
);

    wire [15:0] rx_config_reg;
    wire        rx_config_new;
    wire        an_config_seen;
    wire [7:0]  frame_rx_data_raw;
    wire        frame_rx_valid_raw;

    sgmii_rx u_rx (
        .rx_clk       (rx_clk),
        .rx_rst       (rx_rst),
        .rx_data      (rx_data),
        .rx_k         (rx_k),
        .frame_rx_data(frame_rx_data_raw),
        .frame_rx_valid(frame_rx_valid_raw),
        .frame_rx_last(frame_rx_last),
        .rx_config_reg(rx_config_reg),
        .rx_config_new(rx_config_new)
    );

    // Align frame_rx_last with the final payload byte.
    reg [7:0] rx_prev_data;
    reg       rx_prev_valid;
    always @(posedge rx_clk) begin
        if (rx_rst) begin
            rx_prev_data  <= 8'd0;
            rx_prev_valid <= 1'b0;
        end else begin
            rx_prev_valid <= frame_rx_valid_raw;
            if (frame_rx_valid_raw)
                rx_prev_data <= frame_rx_data_raw;
        end
    end

    // Drop frames that see a code violation (e.g. CTC FIFO slip).
    reg frame_poisoned;
    always @(posedge rx_clk) begin
        if (rx_rst)
            frame_poisoned <= 1'b0;
        else if (frame_rx_last)
            frame_poisoned <= 1'b0;
        else if (rx_cv_err && (frame_rx_valid_raw || rx_prev_valid))
            frame_poisoned <= 1'b1;
    end

    assign frame_rx_data  = rx_prev_data;
    assign frame_rx_valid = rx_prev_valid && !frame_poisoned;

    wire link_up_rx;
    sgmii_an u_an (
        .rx_clk       (rx_clk),
        .rx_rst       (rx_rst),
        .rx_data      (rx_data),
        .rx_k         (rx_k),
        .rx_config_reg(rx_config_reg),
        .rx_config_new(rx_config_new),
        .an_config_seen(an_config_seen),
        .link_up      (link_up_rx)
    );

    // CDC: rx_clk-domain control into tx_clk domain.
    wire link_up_sync;
    wire an_ack_sync;

    sync_ff u_link_up_sync (
        .clk      (tx_clk),
        .rst      (tx_rst),
        .in_level (link_up_rx),
        .out_level(link_up_sync)
    );

    sync_ff u_an_ack_sync (
        .clk      (tx_clk),
        .rst      (tx_rst),
        .in_level (an_config_seen),
        .out_level(an_ack_sync)
    );

    sgmii_tx u_tx (
        .tx_clk       (tx_clk),
        .tx_rst       (tx_rst),
        .frame_tx_data(frame_tx_data),
        .frame_tx_valid(frame_tx_valid),
        .frame_tx_last(frame_tx_last),
        .link_up_sync (link_up_sync),
        .an_ack_sync  (an_ack_sync),
        .tx_data      (tx_data),
        .tx_k         (tx_k),
        .tx_disp      (tx_disp),
        .frame_tx_ready(frame_tx_ready)
    );

endmodule
