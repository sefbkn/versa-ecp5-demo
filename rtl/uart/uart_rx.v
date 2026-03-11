// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright (c) 2026 Youssef Boukenken

module uart_rx (
    input  wire       clk,
    input  wire       rst,
    input  wire       rx_pin,
    output reg  [7:0] data,
    output reg        data_valid
);

    localparam S_IDLE  = 2'd0;
    localparam S_START = 2'd1;
    localparam S_DATA  = 2'd2;
    localparam S_STOP  = 2'd3;
    localparam [4:0] START_TIMER_RELOAD = 5'd11;
    localparam [4:0] BIT_TIMER_RELOAD   = 5'd24;

    reg rx_sync0, rx_sync1;
    always @(posedge clk) begin
        if (rst) begin
            rx_sync0 <= 1'b1;
            rx_sync1 <= 1'b1;
        end else begin
            rx_sync0 <= rx_pin;
            rx_sync1 <= rx_sync0;
        end
    end

    reg [1:0]  state;
    reg [4:0]  bit_timer;
    reg [2:0]  bit_cnt;
    reg [7:0]  shift_reg;

    always @(posedge clk) begin
        if (rst) begin
            state      <= S_IDLE;
            bit_timer  <= 5'd0;
            bit_cnt    <= 0;
            shift_reg  <= 0;
            data       <= 0;
            data_valid <= 1'b0;
        end else begin
            data_valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (!rx_sync1) begin
                        bit_timer <= START_TIMER_RELOAD;
                        state     <= S_START;
                    end
                end

                S_START: begin
                    if (bit_timer == 0) begin
                        if (!rx_sync1) begin
                            bit_timer <= BIT_TIMER_RELOAD;
                            bit_cnt   <= 0;
                            state     <= S_DATA;
                        end else begin
                            state <= S_IDLE;
                        end
                    end else begin
                        bit_timer <= bit_timer - 1'b1;
                    end
                end

                S_DATA: begin
                    if (bit_timer == 0) begin
                        bit_timer <= BIT_TIMER_RELOAD;
                        shift_reg <= {rx_sync1, shift_reg[7:1]};
                        if (bit_cnt == 7) begin
                            state <= S_STOP;
                        end else begin
                            bit_cnt <= bit_cnt + 1;
                        end
                    end else begin
                        bit_timer <= bit_timer - 1'b1;
                    end
                end

                S_STOP: begin
                    if (bit_timer == 0) begin
                        if (rx_sync1) begin
                            data       <= shift_reg;
                            data_valid <= 1'b1;
                        end
                        state <= S_IDLE;
                    end else begin
                        bit_timer <= bit_timer - 1'b1;
                    end
                end
            endcase
        end
    end

endmodule
