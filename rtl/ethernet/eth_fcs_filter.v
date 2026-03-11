// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright (c) 2026 Youssef Boukenken
// Ethernet FCS filter, 8-bit data path.
//
// Sits between a frame source and async_frame_fifo. Delays the frame
// stream by one cycle and checks the FCS. On the output side, drop
// asserts alongside last_out when the CRC does not match the IEEE 802.3
// residue, telling the FIFO to roll back the frame.

module eth_fcs_filter (
    input  wire        clk,
    input  wire        rst,

    input  wire [7:0]  data_in,
    input  wire        valid_in,
    input  wire        last_in,

    output reg  [7:0]  data_out,
    output reg         valid_out,
    output reg         last_out,
    output wire        drop
);

    localparam [31:0] CRC_INIT    = 32'hFFFFFFFF;
    localparam [31:0] CRC_RESIDUE = 32'hDEBB20E3;

    reg [31:0] crc;
    reg        crc_ok_r;

// Generated XOR matrix for 8-bit parallel reflected CRC-32 update,
// mechanically derived from IEEE 802.3 CRC-32 polynomial 0xEDB88320.
function [31:0] crc_next;
    input [31:0] c;
    input [7:0]  d;
    begin
        crc_next[0]  = c[2] ^ c[8] ^ d[2];
        crc_next[1]  = c[0] ^ c[3] ^ c[9] ^ d[0] ^ d[3];
        crc_next[2]  = c[0] ^ c[1] ^ c[4] ^ c[10] ^ d[0] ^ d[1] ^ d[4];
        crc_next[3]  = c[1] ^ c[2] ^ c[5] ^ c[11] ^ d[1] ^ d[2] ^ d[5];
        crc_next[4]  = c[0] ^ c[2] ^ c[3] ^ c[6] ^ c[12] ^ d[0] ^ d[2] ^ d[3] ^ d[6];
        crc_next[5]  = c[1] ^ c[3] ^ c[4] ^ c[7] ^ c[13] ^ d[1] ^ d[3] ^ d[4] ^ d[7];
        crc_next[6]  = c[4] ^ c[5] ^ c[14] ^ d[4] ^ d[5];
        crc_next[7]  = c[0] ^ c[5] ^ c[6] ^ c[15] ^ d[0] ^ d[5] ^ d[6];
        crc_next[8]  = c[1] ^ c[6] ^ c[7] ^ c[16] ^ d[1] ^ d[6] ^ d[7];
        crc_next[9]  = c[7] ^ c[17] ^ d[7];
        crc_next[10] = c[2] ^ c[18] ^ d[2];
        crc_next[11] = c[3] ^ c[19] ^ d[3];
        crc_next[12] = c[0] ^ c[4] ^ c[20] ^ d[0] ^ d[4];
        crc_next[13] = c[0] ^ c[1] ^ c[5] ^ c[21] ^ d[0] ^ d[1] ^ d[5];
        crc_next[14] = c[1] ^ c[2] ^ c[6] ^ c[22] ^ d[1] ^ d[2] ^ d[6];
        crc_next[15] = c[2] ^ c[3] ^ c[7] ^ c[23] ^ d[2] ^ d[3] ^ d[7];
        crc_next[16] = c[0] ^ c[2] ^ c[3] ^ c[4] ^ c[24] ^ d[0] ^ d[2] ^ d[3] ^ d[4];
        crc_next[17] = c[0] ^ c[1] ^ c[3] ^ c[4] ^ c[5] ^ c[25] ^ d[0] ^ d[1] ^ d[3] ^ d[4] ^ d[5];
        crc_next[18] = c[0] ^ c[1] ^ c[2] ^ c[4] ^ c[5] ^ c[6] ^ c[26] ^ d[0] ^ d[1] ^ d[2] ^ d[4] ^ d[5] ^ d[6];
        crc_next[19] = c[1] ^ c[2] ^ c[3] ^ c[5] ^ c[6] ^ c[7] ^ c[27] ^ d[1] ^ d[2] ^ d[3] ^ d[5] ^ d[6] ^ d[7];
        crc_next[20] = c[3] ^ c[4] ^ c[6] ^ c[7] ^ c[28] ^ d[3] ^ d[4] ^ d[6] ^ d[7];
        crc_next[21] = c[2] ^ c[4] ^ c[5] ^ c[7] ^ c[29] ^ d[2] ^ d[4] ^ d[5] ^ d[7];
        crc_next[22] = c[2] ^ c[3] ^ c[5] ^ c[6] ^ c[30] ^ d[2] ^ d[3] ^ d[5] ^ d[6];
        crc_next[23] = c[3] ^ c[4] ^ c[6] ^ c[7] ^ c[31] ^ d[3] ^ d[4] ^ d[6] ^ d[7];
        crc_next[24] = c[0] ^ c[2] ^ c[4] ^ c[5] ^ c[7] ^ d[0] ^ d[2] ^ d[4] ^ d[5] ^ d[7];
        crc_next[25] = c[0] ^ c[1] ^ c[2] ^ c[3] ^ c[5] ^ c[6] ^ d[0] ^ d[1] ^ d[2] ^ d[3] ^ d[5] ^ d[6];
        crc_next[26] = c[0] ^ c[1] ^ c[2] ^ c[3] ^ c[4] ^ c[6] ^ c[7] ^ d[0] ^ d[1] ^ d[2] ^ d[3] ^ d[4] ^ d[6] ^ d[7];
        crc_next[27] = c[1] ^ c[3] ^ c[4] ^ c[5] ^ c[7] ^ d[1] ^ d[3] ^ d[4] ^ d[5] ^ d[7];
        crc_next[28] = c[0] ^ c[4] ^ c[5] ^ c[6] ^ d[0] ^ d[4] ^ d[5] ^ d[6];
        crc_next[29] = c[0] ^ c[1] ^ c[5] ^ c[6] ^ c[7] ^ d[0] ^ d[1] ^ d[5] ^ d[6] ^ d[7];
        crc_next[30] = c[0] ^ c[1] ^ c[6] ^ c[7] ^ d[0] ^ d[1] ^ d[6] ^ d[7];
        crc_next[31] = c[1] ^ c[7] ^ d[1] ^ d[7];
    end
endfunction

    wire [31:0] crc_next_val = crc_next(crc, data_in);

    // CRC accumulator + registered residue check.
    always @(posedge clk) begin
        if (rst) begin
            crc    <= CRC_INIT;
            crc_ok_r <= 1'b0;
        end else if (valid_in) begin
            crc    <= crc_next_val;
            crc_ok_r <= (crc_next_val == CRC_RESIDUE);
        end else begin
            crc    <= CRC_INIT;
        end
    end

    // One-cycle pipeline delay so the registered crc_ok_r is ready
    // when last_out reaches the FIFO.
    always @(posedge clk) begin
        if (rst) begin
            data_out  <= 8'd0;
            valid_out <= 1'b0;
            last_out  <= 1'b0;
        end else begin
            data_out  <= data_in;
            valid_out <= valid_in;
            last_out  <= last_in;
        end
    end

    assign drop = last_out && !crc_ok_r;

endmodule
