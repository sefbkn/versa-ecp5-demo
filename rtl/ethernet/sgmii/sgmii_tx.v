// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright (c) 2026 Youssef Boukenken

// SGMII TX protocol generator (tx_clk domain).
//
// Emits ordered sets, idles, and framed payload symbols to DCU.

module sgmii_tx (
    input  wire       tx_clk,
    input  wire       tx_rst,

    input  wire [7:0] frame_tx_data,
    input  wire       frame_tx_valid,
    input  wire       frame_tx_last,

    // Synchronized AN/link inputs from rx_clk domain
    input  wire       link_up_sync,
    input  wire       an_ack_sync,

    output reg  [7:0] tx_data,
    output reg        tx_k,
    output reg        tx_disp,
    output wire       frame_tx_ready
);

    // Symbol constants
    localparam [7:0] K28_5 = 8'hBC;  // Comma
    localparam [7:0] K27_7 = 8'hFB;  // Start of packet /S/
    localparam [7:0] K29_7 = 8'hFD;  // End of packet /T/
    localparam [7:0] K23_7 = 8'hF7;  // Carrier extend /R/

    // D-codes for config/idle indicators
    localparam [7:0] D21_5 = 8'hB5;  // /C1/ config indicator
    localparam [7:0] D2_2  = 8'h42;  // /C2/ config indicator
    localparam [7:0] D16_2 = 8'h50;  // /I2/ idle

    // Dynamic config word:
    //   0x1801 before ACK, 0xD801 after ACK.
    wire [15:0] tx_config_word = {
        an_ack_sync,  // bit 15: link
        an_ack_sync,  // bit 14: ack
        1'b0,         // bit 13: reserved
        1'b1,         // bit 12: full duplex
        2'b10,        // bits [11:10]: 1000 Mbps
        9'b0,         // bits [9:1]: reserved
        1'b1          // bit 0: valid
    };

    localparam [3:0]
        TX_START      = 4'd0,
        TX_CONFIG_D   = 4'd1,
        TX_CONFIG_LSB = 4'd2,
        TX_CONFIG_MSB = 4'd3,
        TX_IDLE       = 4'd4,
        TX_DATA       = 4'd5,
        TX_CEOP       = 4'd6,
        TX_CEXT1      = 4'd7,
        TX_CEXT2      = 4'd8,
        TX_PREAMBLE   = 4'd9,
        TX_SFD        = 4'd10,
        TX_IFG        = 4'd11;

    reg [3:0] tx_state;
    reg       tx_ctype;
    reg       tx_parity;
    reg       tx_ifg_phase;
    reg [2:0] tx_preamble_cnt;
    reg [3:0] tx_ifg_cnt;

    // Only consume FIFO payload in TX_DATA.
    assign frame_tx_ready = (tx_state == TX_DATA);

    always @(posedge tx_clk) begin
        if (tx_rst) begin
            tx_state        <= TX_START;
            tx_data         <= K28_5;
            tx_k            <= 1'b1;
            tx_disp         <= 1'b0;
            tx_ctype        <= 1'b0;
            tx_parity       <= 1'b0;
            tx_ifg_phase    <= 1'b0;
            tx_preamble_cnt <= 3'd0;
            tx_ifg_cnt      <= 4'd0;
        end else begin
            tx_disp   <= 1'b0;
            tx_parity <= ~tx_parity;

            case (tx_state)
                TX_START: begin
                    if (!link_up_sync) begin
                        tx_data  <= K28_5;
                        tx_k     <= 1'b1;
                        tx_state <= TX_CONFIG_D;
                    end else if (frame_tx_valid) begin
                        tx_data  <= K27_7;
                        tx_k     <= 1'b1;
                        tx_preamble_cnt <= 3'd0;
                        tx_state <= TX_PREAMBLE;
                    end else begin
                        tx_data  <= K28_5;
                        tx_k     <= 1'b1;
                        tx_state <= TX_IDLE;
                    end
                end

                TX_CONFIG_D: begin
                    tx_data  <= tx_ctype ? D2_2 : D21_5;
                    tx_k     <= 1'b0;
                    tx_ctype <= ~tx_ctype;
                    tx_state <= TX_CONFIG_LSB;
                end

                TX_CONFIG_LSB: begin
                    tx_data  <= tx_config_word[7:0];
                    tx_k     <= 1'b0;
                    tx_state <= TX_CONFIG_MSB;
                end

                TX_CONFIG_MSB: begin
                    tx_data  <= tx_config_word[15:8];
                    tx_k     <= 1'b0;
                    tx_state <= TX_START;
                end

                TX_IDLE: begin
                    tx_data  <= D16_2;
                    tx_k     <= 1'b0;
                    tx_disp  <= 1'b1;
                    tx_state <= TX_START;
                end

                TX_DATA: begin
                    if (frame_tx_valid) begin
                        tx_data <= frame_tx_data;
                        tx_k    <= 1'b0;
                        if (frame_tx_last)
                            tx_state <= TX_CEOP;
                    end else begin
                        tx_data  <= K29_7;
                        tx_k     <= 1'b1;
                        tx_state <= TX_CEXT1;
                    end
                end

                TX_CEOP: begin
                    tx_data  <= K29_7;
                    tx_k     <= 1'b1;
                    tx_state <= TX_CEXT1;
                end

                TX_CEXT1: begin
                    tx_data  <= K23_7;
                    tx_k     <= 1'b1;
                    if (tx_parity) begin
                        tx_ifg_phase <= 1'b0;
                        tx_ifg_cnt   <= 4'd10;  // 10 idles = 5 /I2/ pairs (+ /T/R/ = 12 byte-times IFG)
                        tx_state     <= TX_IFG;
                    end else
                        tx_state <= TX_CEXT2;
                end

                TX_CEXT2: begin
                    tx_data  <= K23_7;
                    tx_k     <= 1'b1;
                    tx_ifg_phase <= 1'b0;
                    tx_ifg_cnt   <= 4'd10;  // 10 idles = 5 /I2/ pairs (+ /T/R/R/ = 13 byte-times IFG)
                    tx_state     <= TX_IFG;
                end

                TX_IFG: begin
                    if (!tx_ifg_phase) begin
                        tx_data <= K28_5;
                        tx_k    <= 1'b1;
                    end else begin
                        tx_data <= D16_2;
                        tx_k    <= 1'b0;
                        tx_disp <= 1'b1;
                    end

                    tx_ifg_phase <= ~tx_ifg_phase;
                    if (tx_ifg_cnt == 4'd1) begin
                        tx_ifg_cnt <= 4'd0;
                        tx_state   <= TX_START;
                    end else begin
                        tx_ifg_cnt <= tx_ifg_cnt - 1'b1;
                    end
                end

                TX_PREAMBLE: begin
                    tx_data <= 8'h55;
                    tx_k    <= 1'b0;
                    if (tx_preamble_cnt == 3'd5)
                        tx_state <= TX_SFD;
                    else
                        tx_preamble_cnt <= tx_preamble_cnt + 1'b1;
                end

                TX_SFD: begin
                    tx_data  <= 8'hD5;
                    tx_k     <= 1'b0;
                    tx_state <= TX_DATA;
                end

                default: begin
                    tx_state <= TX_START;
                    tx_data  <= K28_5;
                    tx_k     <= 1'b1;
                    tx_ifg_phase <= 1'b0;
                    tx_ifg_cnt   <= 4'd0;
                end
            endcase
        end
    end

endmodule
