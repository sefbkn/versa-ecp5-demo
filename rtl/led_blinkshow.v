// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright (c) 2026 Youssef Boukenken

// LED blink show: sweep right, sweep left, even/odd blink, repeat.
//
// Steps  0-7:  sweep right (1s total, 125ms/step)
// Steps  8-15: sweep left  (1s total, 125ms/step)
// Steps 16-21: even/odd alternation (1s per phase)
module led_blinkshow #(
    parameter CLK_HZ = 100_000_000
) (
    input  wire       clk,
    output wire [7:0] led
);

    localparam [26:0] SWEEP_LIMIT = CLK_HZ / 8 - 1;
    localparam [26:0] BLINK_LIMIT = CLK_HZ - 1;

    reg [26:0] div = 0;
    reg [4:0]  step = 0;
    wire [26:0] limit = (step < 5'd16) ? SWEEP_LIMIT : BLINK_LIMIT;

    always @(posedge clk) begin
        if (div >= limit) begin
            div  <= 0;
            step <= (step == 5'd21) ? 5'd0 : step + 1'b1;
        end else begin
            div <= div + 1'b1;
        end
    end

    reg [7:0] pattern;
    always @(*) begin
        if (step < 5'd8)
            pattern = 8'd1 << step[2:0];
        else if (step < 5'd16)
            pattern = 8'b1000_0000 >> step[2:0];
        else if (step[0])
            pattern = 8'b10101010;
        else
            pattern = 8'b01010101;
    end

    assign led = ~pattern;

endmodule
