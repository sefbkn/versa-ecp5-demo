// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright (c) 2026 Youssef Boukenken

module instr_rom #(
    parameter SIZE = 16384,
    parameter INIT_FILE = ""
) (
    input  wire                      clk,
    input  wire [$clog2(SIZE/4)-1:0] addr_a,
    output reg  [31:0]               rdata_a,
    input  wire [$clog2(SIZE/4)-1:0] addr_b,
    output reg  [31:0]               rdata_b
);

    localparam WORDS = SIZE / 4;

    (* ram_style = "block" *)
    reg [31:0] mem [0:WORDS-1];

    initial begin
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, mem);
        end
    end

    always @(posedge clk) begin
        rdata_a <= mem[addr_a];
        rdata_b <= mem[addr_b];
    end

endmodule
