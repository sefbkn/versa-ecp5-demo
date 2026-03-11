// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright (c) 2026 Youssef Boukenken

// RGMII TX frame formatter.
//
// Consumes the common payload-only frame stream and inserts Ethernet
// preamble/SFD. rgmii_port performs the final launch-edge staging.

module rgmii_tx #(
    parameter INSERT_PREAMBLE = 1
) (
    input  wire        tx_clk,
    input  wire        tx_rst,

    input  wire [7:0]  frame_tx_data,
    input  wire        frame_tx_valid,
    input  wire        frame_tx_last,
    output wire        frame_tx_ready,

    output reg  [7:0]  tx_data,
    output reg         tx_valid
);

    reg [1:0] tx_state;
    reg [2:0] tx_preamble_cnt;
    reg [3:0] tx_ifg_cnt;

    localparam [1:0]
        TX_IDLE     = 2'd0,
        TX_PREAMBLE = 2'd1,
        TX_SFD      = 2'd2,
        TX_DATA     = 2'd3;

    assign frame_tx_ready = INSERT_PREAMBLE ? (tx_state == TX_DATA) : 1'b1;

    always @(posedge tx_clk) begin
        if (tx_rst) begin
            tx_data         <= 8'd0;
            tx_valid        <= 1'b0;
            tx_state        <= TX_IDLE;
            tx_preamble_cnt <= 3'd0;
            tx_ifg_cnt      <= 4'd0;
        end else if (!INSERT_PREAMBLE) begin
            tx_data  <= frame_tx_data;
            tx_valid <= frame_tx_valid;
        end else begin
            case (tx_state)
                TX_IDLE: begin
                    tx_valid <= 1'b0;
                    if (tx_ifg_cnt != 4'd0) begin
                        tx_ifg_cnt <= tx_ifg_cnt - 1'b1;
                    end else if (frame_tx_valid) begin
                        tx_data         <= 8'h55;
                        tx_valid        <= 1'b1;
                        tx_preamble_cnt <= 3'd0;
                        tx_state        <= TX_PREAMBLE;
                    end
                end

                TX_PREAMBLE: begin
                    tx_data  <= 8'h55;
                    tx_valid <= 1'b1;
                    if (tx_preamble_cnt == 3'd5)
                        tx_state <= TX_SFD;
                    else
                        tx_preamble_cnt <= tx_preamble_cnt + 1'b1;
                end

                TX_SFD: begin
                    tx_data  <= 8'hD5;
                    tx_valid <= 1'b1;
                    tx_state <= TX_DATA;
                end

                TX_DATA: begin
                    if (frame_tx_valid) begin
                        tx_data  <= frame_tx_data;
                        tx_valid <= 1'b1;
                        if (frame_tx_last) begin
                            tx_ifg_cnt <= 4'd12;
                            tx_state <= TX_IDLE;
                        end
                    end else begin
                        tx_valid <= 1'b0;
                        tx_ifg_cnt <= 4'd12;
                        tx_state <= TX_IDLE;
                    end
                end

                default: begin
                    tx_valid <= 1'b0;
                    tx_ifg_cnt <= 4'd0;
                    tx_state <= TX_IDLE;
                end
            endcase
        end
    end

endmodule
