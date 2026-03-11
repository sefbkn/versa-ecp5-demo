// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright (c) 2026 Youssef Boukenken

// Asynchronous frame FIFO using:
// - byte payload ring buffer
// - frame descriptor FIFO (frame lengths)
// - write-side frame commit, where a wr_valid gap before wr_last aborts the frame

(* keep_hierarchy = "yes" *)
module async_frame_fifo #(
    // Payload ring size in bytes, must be non-zero power of two.
    parameter PAYLOAD_SIZE = 2048,
    // Frame descriptor queue depth, must be non-zero power of two.
    parameter MAX_FRAMES = 32
) (
    input  wire       wr_clk,
    input  wire       wr_rst,
    input  wire [7:0] wr_data,
    input  wire       wr_valid,
    input  wire       wr_last,
    input  wire       wr_drop,

    input  wire       rd_clk,
    input  wire       rd_rst,
    output wire [7:0] rd_data,
    output wire       rd_valid,
    output wire       rd_last,
    input  wire       rd_ready
);
    generate
        if (PAYLOAD_SIZE < 2 || (PAYLOAD_SIZE & (PAYLOAD_SIZE - 1)) != 0) begin : g_bad_payload_size
            initial $error("PAYLOAD_SIZE must be >= 2 and a power of two");
        end
        if (MAX_FRAMES < 2 || (MAX_FRAMES & (MAX_FRAMES - 1)) != 0) begin : g_bad_max_frames
            initial $error("MAX_FRAMES must be >= 2 and a power of two");
        end
    endgenerate

    localparam AW = $clog2(PAYLOAD_SIZE);
    localparam FW = $clog2(MAX_FRAMES);
    localparam LENW = AW + 1;

    (* ram_style = "block" *) reg [7:0] payload_mem [0:PAYLOAD_SIZE-1];
    reg [LENW-1:0] desc_mem [0:MAX_FRAMES-1];

    // Pointer helpers
    function [AW:0] bin2gray_aw(input [AW:0] b);
        bin2gray_aw = b ^ (b >> 1);
    endfunction

    function [AW:0] gray_full_aw(input [AW:0] g);
        begin
            gray_full_aw = g;
            gray_full_aw[AW] = ~g[AW];
            gray_full_aw[AW-1] = ~g[AW-1];
        end
    endfunction

    function [FW:0] bin2gray_fw(input [FW:0] b);
        bin2gray_fw = b ^ (b >> 1);
    endfunction

    function [FW:0] gray2bin_fw(input [FW:0] g);
        reg [FW:0] b;
        integer i;
        begin
            b[FW] = g[FW];
            for (i = FW-1; i >= 0; i = i - 1)
                b[i] = b[i+1] ^ g[i];
            gray2bin_fw = b;
        end
    endfunction

    function [FW:0] gray_full_fw(input [FW:0] g);
        begin
            gray_full_fw = g;
            gray_full_fw[FW] = ~g[FW];
            gray_full_fw[FW-1] = ~g[FW-1];
        end
    endfunction

    // Write domain: payload ring + descriptor enqueue
    reg [AW:0] wr_ptr;
    reg [AW:0] frame_start_ptr;
    reg [LENW-1:0] frame_len;
    reg in_frame;
    reg frame_overflow;

    reg [FW:0] wr_desc_ptr;
    reg [FW:0] wr_desc_gray_r;

    wire [AW:0] rd_rel_gray_ws1;
    wire [FW:0] rd_desc_gray_ws1;

    wire [AW:0] wr_ptr_next = wr_ptr + 1'b1;
    wire [AW:0] wr_ptr_gray = bin2gray_aw(wr_ptr);
    wire payload_full = (wr_ptr_gray == gray_full_aw(rd_rel_gray_ws1));
    wire [FW:0] wr_desc_next = wr_desc_ptr + 1'b1;
    wire [FW:0] wr_desc_next_gray = bin2gray_fw(wr_desc_next);
    wire desc_full = (wr_desc_gray_r == gray_full_fw(rd_desc_gray_ws1));
    wire wr_accept_byte = wr_valid && !frame_overflow && !payload_full;
    wire wr_commit_desc = wr_accept_byte && wr_last && !desc_full && !wr_drop;
    wire [LENW-1:0] frame_len_inc = frame_len + 1'b1;

    // Read domain: descriptor dequeue + payload stream
    reg [AW:0] rd_fetch_ptr;
    reg [AW:0] rd_release_ptr;
    reg [AW:0] rd_release_gray_r;

    reg [FW:0] rd_desc_ptr;
    reg [FW:0] rd_desc_gray_r;

    wire [FW:0] wr_desc_gray_rs1;
    wire [FW:0] wr_desc_ptr_sync = gray2bin_fw(wr_desc_gray_rs1);
    wire desc_available = (wr_desc_ptr_sync != rd_desc_ptr);
    wire [LENW-1:0] desc_len_curr = desc_mem[rd_desc_ptr[FW-1:0]];

    reg [7:0] ram_out;
    reg [7:0] rd_data_r;
    reg rd_valid_r;
    reg rd_last_r;
    reg rd_reading;
    reg [LENW-1:0] rd_bytes_left;
    reg [LENW-1:0] rd_next_frame_len;
    reg rd_next_frame_valid;
    reg prefetch_payload_t;

    assign rd_data = rd_data_r;
    assign rd_valid = rd_valid_r;
    assign rd_last = rd_last_r;

    // Gray-pointer CDC synchronizers.
    sync_ff #(
        .WIDTH(AW + 1)
    ) u_rd_rel_gray_sync (
        .clk(wr_clk),
        .rst(wr_rst),
        .in_level(rd_release_gray_r),
        .out_level(rd_rel_gray_ws1)
    );

    sync_ff #(
        .WIDTH(FW + 1)
    ) u_rd_desc_gray_sync (
        .clk(wr_clk),
        .rst(wr_rst),
        .in_level(rd_desc_gray_r),
        .out_level(rd_desc_gray_ws1)
    );

    sync_ff #(
        .WIDTH(FW + 1)
    ) u_wr_desc_gray_sync (
        .clk(rd_clk),
        .rst(rd_rst),
        .in_level(wr_desc_gray_r),
        .out_level(wr_desc_gray_rs1)
    );

    // Write clock process
    always @(posedge wr_clk) begin
        if (wr_rst) begin
            wr_ptr          <= 0;
            frame_start_ptr <= 0;
            frame_len       <= 0;
            in_frame        <= 1'b0;
            frame_overflow  <= 1'b0;
            wr_desc_ptr     <= 0;
            wr_desc_gray_r  <= 0;
        end else begin
            if (wr_valid) begin
                // First byte of a new frame.
                if (!in_frame) begin
                    in_frame        <= 1'b1;
                    frame_start_ptr <= wr_ptr;
                    frame_len       <= 0;
                    frame_overflow  <= 1'b0;
                end

                // Accept payload bytes while room remains and frame not marked overflowed.
                if (wr_accept_byte) begin
                    payload_mem[wr_ptr[AW-1:0]] <= wr_data;
                    wr_ptr <= wr_ptr_next;
                    frame_len <= frame_len_inc;
                end else begin
                    frame_overflow <= 1'b1;
                end

                if (wr_last) begin
                    in_frame <= 1'b0;

                    // Commit frame descriptor only if payload and metadata both fit.
                    if (wr_commit_desc) begin
                        desc_mem[wr_desc_ptr[FW-1:0]] <= frame_len_inc;
                        wr_desc_ptr <= wr_desc_next;
                        wr_desc_gray_r <= wr_desc_next_gray;
                    end else begin
                        // Drop frame and rollback payload pointer to start-of-frame.
                        wr_ptr <= in_frame ? frame_start_ptr : wr_ptr;
                    end

                    frame_len <= 0;
                    frame_overflow <= 1'b0;
                end
            end else if (in_frame) begin
                // Gap before wr_last means incomplete frame; discard.
                wr_ptr <= frame_start_ptr;
                in_frame <= 1'b0;
                frame_len <= 0;
                frame_overflow <= 1'b0;
            end
        end
    end

    // Read clock process
    always @(posedge rd_clk) begin
        if (rd_rst) begin
            rd_fetch_ptr <= 0;
            rd_release_ptr <= 0;
            rd_release_gray_r <= 0;
            rd_desc_ptr <= 0;
            rd_desc_gray_r <= 0;
            rd_valid_r <= 1'b0;
            rd_last_r <= 1'b0;
            rd_reading <= 1'b0;
            rd_bytes_left <= 0;
            rd_next_frame_len <= 0;
            rd_next_frame_valid <= 1'b0;
            ram_out <= 8'd0;
            rd_data_r <= 8'd0;
        end else begin
            rd_release_gray_r <= bin2gray_aw(rd_release_ptr);
            rd_desc_gray_r <= bin2gray_fw(rd_desc_ptr);

            if (!rd_valid_r || rd_ready) begin
                // Output stage.
                if (rd_reading) begin
                    rd_data_r <= ram_out;
                    rd_valid_r <= 1'b1;
                    rd_last_r <= (rd_bytes_left == 1);
                    rd_release_ptr <= rd_release_ptr + 1'b1;
                    if (rd_bytes_left != 0)
                        rd_bytes_left <= rd_bytes_left - 1'b1;
                end else begin
                    rd_valid_r <= 1'b0;
                    rd_last_r <= 1'b0;
                end

                // Queue one descriptor length ahead of time.
                if (!rd_next_frame_valid && desc_available) begin
                    rd_next_frame_len <= desc_len_curr;
                    rd_next_frame_valid <= 1'b1;
                    rd_desc_ptr <= rd_desc_ptr + 1'b1;
                end

                // Decide whether to prefetch next payload byte.
                prefetch_payload_t = 1'b0;
                if (rd_reading && (rd_bytes_left > 1)) begin
                    prefetch_payload_t = 1'b1;
                    rd_reading <= 1'b1;
                end else if (rd_next_frame_valid) begin
                    rd_bytes_left <= rd_next_frame_len;
                    rd_next_frame_valid <= 1'b0;
                    prefetch_payload_t = 1'b1;
                    rd_reading <= 1'b1;
                end else begin
                    rd_reading <= 1'b0;
                end

                // Single read site keeps payload_mem inference stable.
                if (prefetch_payload_t) begin
                    ram_out <= payload_mem[rd_fetch_ptr[AW-1:0]];
                    rd_fetch_ptr <= rd_fetch_ptr + 1'b1;
                end
            end
        end
    end

endmodule
