// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright (c) 2026 Youssef Boukenken

module uart_tx (
    input  wire       clk,
    input  wire       rst,
    input  wire [7:0] data,
    input  wire       data_valid,
    output reg        tx_pin,
    output wire       ready
);

    localparam S_IDLE  = 2'd0;
    localparam S_START = 2'd1;
    localparam S_DATA  = 2'd2;
    localparam S_STOP  = 2'd3;
    localparam [4:0] BIT_TIMER_RELOAD = 5'd24;

    reg [1:0]  state;
    reg [4:0]  bit_timer;
    reg [2:0]  bit_cnt;
    reg [7:0]  shift_reg;

    assign ready = (state == S_IDLE);

    always @(posedge clk) begin
        if (rst) begin
            state     <= S_IDLE;
            tx_pin    <= 1'b1;
            bit_timer <= 5'd0;
            bit_cnt   <= 0;
            shift_reg <= 0;
        end else begin
            case (state)
                S_IDLE: begin
                    tx_pin <= 1'b1;
                    if (data_valid) begin
                        shift_reg <= data;
                        state     <= S_START;
                        bit_timer <= BIT_TIMER_RELOAD;
                    end
                end

                S_START: begin
                    tx_pin <= 1'b0;
                    if (bit_timer == 0) begin
                        bit_timer <= BIT_TIMER_RELOAD;
                        state     <= S_DATA;
                        bit_cnt   <= 0;
                    end else begin
                        bit_timer <= bit_timer - 1'b1;
                    end
                end

                S_DATA: begin
                    tx_pin <= shift_reg[0];
                    if (bit_timer == 0) begin
                        bit_timer <= BIT_TIMER_RELOAD;
                        shift_reg <= {1'b0, shift_reg[7:1]};
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
                    tx_pin <= 1'b1;
                    if (bit_timer == 0) begin
                        state <= S_IDLE;
                    end else begin
                        bit_timer <= bit_timer - 1'b1;
                    end
                end
            endcase
        end
    end

endmodule
