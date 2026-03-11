// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright (c) 2026 Youssef Boukenken

// Two-stage synchronizer for CDC of level-style controls.
// Optional async reset assertion; deassertion is synchronized to clk.
module sync_ff #(
    parameter integer WIDTH = 1,
    parameter [WIDTH-1:0] RESET_VAL = {WIDTH{1'b0}}
) (
    input  wire             clk,
    input  wire             rst,
    input  wire [WIDTH-1:0] in_level,
    output wire [WIDTH-1:0] out_level
);
    reg [WIDTH-1:0] s0 = RESET_VAL;
    reg [WIDTH-1:0] s1 = RESET_VAL;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            s0 <= RESET_VAL;
            s1 <= RESET_VAL;
        end else begin
            s0 <= in_level;
            s1 <= s0;
        end
    end

    assign out_level = s1;
endmodule
