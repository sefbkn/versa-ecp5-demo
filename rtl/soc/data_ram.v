// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright (c) 2026 Youssef Boukenken

module data_ram #(
    parameter SIZE = 4096,
    parameter INIT_FILE = ""
) (
    input  wire                      clk,
    input  wire [$clog2(SIZE/4)-1:0] addr,
    input  wire [31:0]               wdata,
    input  wire [3:0]                we,
    output reg  [31:0]               rdata
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
        rdata <= mem[addr];

        if (we[0]) mem[addr][7:0]   <= wdata[7:0];
        if (we[1]) mem[addr][15:8]  <= wdata[15:8];
        if (we[2]) mem[addr][23:16] <= wdata[23:16];
        if (we[3]) mem[addr][31:24] <= wdata[31:24];
    end

endmodule
