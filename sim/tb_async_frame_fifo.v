`timescale 1ns/1ps
`default_nettype none

module tb_async_frame_fifo;
    localparam integer PAYLOAD_SIZE = 16;
    localparam integer MAX_FRAMES = 8;
    localparam integer MAX_BYTES = 8192;

    reg wr_clk = 1'b0;
    reg rd_clk = 1'b0;
    integer wr_half_period_ns = 4;
    integer rd_half_period_ns = 4;

    reg wr_rst = 1'b1;
    reg [7:0] wr_data = 8'h00;
    reg wr_valid = 1'b0;
    reg wr_last = 1'b0;
    reg wr_drop = 1'b0;

    reg rd_rst = 1'b1;
    wire [7:0] rd_data;
    wire rd_valid;
    wire rd_last;
    reg rd_ready = 1'b1;

    reg [7:0] expected_data [0:MAX_BYTES-1];
    reg       expected_last [0:MAX_BYTES-1];
    integer expected_count = 0;
    integer observed_count = 0;
    integer error_count = 0;

    async_frame_fifo #(
        .PAYLOAD_SIZE(PAYLOAD_SIZE),
        .MAX_FRAMES(MAX_FRAMES)
    ) dut (
        .wr_clk(wr_clk),
        .wr_rst(wr_rst),
        .wr_data(wr_data),
        .wr_valid(wr_valid),
        .wr_last(wr_last),
        .wr_drop(wr_drop),
        .rd_clk(rd_clk),
        .rd_rst(rd_rst),
        .rd_data(rd_data),
        .rd_valid(rd_valid),
        .rd_last(rd_last),
        .rd_ready(rd_ready)
    );

    always #(wr_half_period_ns) wr_clk = ~wr_clk;
    always #(rd_half_period_ns) rd_clk = ~rd_clk;

    always @(posedge rd_clk) begin
        if (!rd_rst && rd_valid && rd_ready) begin
            if (observed_count >= expected_count) begin
                $display("FAIL: unexpected output byte=0x%02x last=%0d at t=%0t",
                         rd_data, rd_last, $time);
                error_count = error_count + 1;
            end else begin
                if (rd_data !== expected_data[observed_count]) begin
                    $display("FAIL: data mismatch idx=%0d exp=0x%02x got=0x%02x at t=%0t",
                             observed_count, expected_data[observed_count], rd_data, $time);
                    error_count = error_count + 1;
                end
                if (rd_last !== expected_last[observed_count]) begin
                    $display("FAIL: last mismatch idx=%0d exp=%0d got=%0d at t=%0t",
                             observed_count, expected_last[observed_count], rd_last, $time);
                    error_count = error_count + 1;
                end
            end
            observed_count = observed_count + 1;
        end
    end

    task clear_expected;
        begin
            expected_count = 0;
            observed_count = 0;
        end
    endtask

    task push_expected;
        input [7:0] data;
        input       last;
        begin
            if (expected_count >= MAX_BYTES) begin
                $display("FAIL: expected queue overflow");
                error_count = error_count + 1;
            end else begin
                expected_data[expected_count] = data;
                expected_last[expected_count] = last;
                expected_count = expected_count + 1;
            end
        end
    endtask

    task apply_reset;
        begin
            wr_rst = 1'b1;
            rd_rst = 1'b1;
            wr_valid = 1'b0;
            wr_last = 1'b0;
            wr_drop = 1'b0;
            wr_data = 8'h00;
            rd_ready = 1'b1;

            repeat (4) @(posedge wr_clk);
            repeat (4) @(posedge rd_clk);

            wr_rst = 1'b0;
            rd_rst = 1'b0;
            repeat (2) @(posedge wr_clk);
        end
    endtask

    function [7:0] frame_payload;
        input integer frame_id;
        input integer index;
        begin
            frame_payload = {frame_id[3:0], index[3:0]};
        end
    endfunction

    function [7:0] dropped_payload;
        input integer frame_id;
        input integer index;
        begin
            dropped_payload = 8'hD0 | {frame_id[1:0], index[5:0]};
        end
    endfunction

    function [7:0] aborted_payload;
        input integer frame_id;
        input integer index;
        begin
            aborted_payload = 8'h80 | {frame_id[2:0], index[4:0]};
        end
    endfunction

    task expect_frame;
        input integer frame_id;
        input integer length;
        integer i;
        reg [7:0] payload;
        begin
            for (i = 0; i < length; i = i + 1) begin
                payload = frame_payload(frame_id, i);
                push_expected(payload, (i == (length - 1)));
            end
        end
    endtask

    task send_frame;
        input integer frame_id;
        input integer length;
        integer i;
        reg [7:0] payload;
        begin
            for (i = 0; i < length; i = i + 1) begin
                payload = frame_payload(frame_id, i);
                @(negedge wr_clk);
                wr_valid = 1'b1;
                wr_data = payload;
                wr_last = (i == (length - 1));
                @(posedge wr_clk);
            end

            @(negedge wr_clk);
            wr_valid = 1'b0;
            wr_last = 1'b0;
            wr_data = 8'h00;
        end
    endtask

    task send_dropped_frame;
        input integer frame_id;
        input integer length;
        integer i;
        reg [7:0] payload;
        begin
            for (i = 0; i < length; i = i + 1) begin
                payload = dropped_payload(frame_id, i);
                @(negedge wr_clk);
                wr_valid = 1'b1;
                wr_data = payload;
                wr_last = (i == (length - 1));
                wr_drop = (i == (length - 1));
                @(posedge wr_clk);
            end

            @(negedge wr_clk);
            wr_valid = 1'b0;
            wr_last = 1'b0;
            wr_drop = 1'b0;
            wr_data = 8'h00;
        end
    endtask

    task send_aborted_frame;
        input integer frame_id;
        input integer length;
        integer i;
        reg [7:0] payload;
        begin
            for (i = 0; i < length; i = i + 1) begin
                payload = aborted_payload(frame_id, i);
                @(negedge wr_clk);
                wr_valid = 1'b1;
                wr_data = payload;
                wr_last = 1'b0;
                @(posedge wr_clk);
            end

            @(negedge wr_clk);
            wr_valid = 1'b0;
            wr_last = 1'b0;
            wr_data = 8'h00;
        end
    endtask

    task wait_for_expected_output;
        input integer timeout_cycles;
        integer cycles;
        begin
            cycles = 0;
            while ((observed_count < expected_count) && (cycles < timeout_cycles)) begin
                @(posedge rd_clk);
                cycles = cycles + 1;
            end

            if (observed_count < expected_count) begin
                $display("FAIL: timeout waiting for drain observed=%0d expected=%0d",
                         observed_count, expected_count);
                error_count = error_count + 1;
            end

            // Extra cycles to catch unexpected trailing data.
            repeat (8) @(posedge rd_clk);
        end
    endtask

    function integer frame_len;
        input integer idx;
        begin
            case (idx[2:0])
                3'd0: frame_len = 3;
                3'd1: frame_len = 5;
                3'd2: frame_len = 1;
                3'd3: frame_len = 6;
                3'd4: frame_len = 4;
                3'd5: frame_len = 2;
                3'd6: frame_len = 7;
                default: frame_len = 3;
            endcase
        end
    endfunction

    task run_same_clock_test;
        integer f;
        begin
            $display("TEST: same-clock order + wrap");
            wr_half_period_ns = 4;
            rd_half_period_ns = 4;
            clear_expected();
            apply_reset();

            send_aborted_frame(0, 5);
            repeat (20) @(posedge rd_clk);

            for (f = 0; f < 24; f = f + 1) begin
                expect_frame(f, frame_len(f));
                send_frame(f, frame_len(f));
            end

            wait_for_expected_output(2000);
            if (expected_count <= PAYLOAD_SIZE) begin
                $display("FAIL: same-clock test did not exceed FIFO depth");
                error_count = error_count + 1;
            end
        end
    endtask

    task run_dual_clock_test;
        integer f;
        begin
            $display("TEST: dual-clock order + wrap");
            wr_half_period_ns = 5;
            rd_half_period_ns = 3;
            clear_expected();
            apply_reset();

            send_aborted_frame(1, 6);
            repeat (24) @(posedge rd_clk);

            for (f = 0; f < 28; f = f + 1) begin
                expect_frame(f + 32, frame_len(f + 3));
                send_frame(f + 32, frame_len(f + 3));
            end

            wait_for_expected_output(3000);
            if (expected_count <= PAYLOAD_SIZE) begin
                $display("FAIL: dual-clock test did not exceed FIFO depth");
                error_count = error_count + 1;
            end
        end
    endtask

    task run_payload_full_test;
        integer f;
        begin
            $display("TEST: payload-full keeps older frames intact");
            wr_half_period_ns = 4;
            rd_half_period_ns = 4;
            clear_expected();
            apply_reset();

            // Hold the read domain in reset so no hidden prefetch can consume bytes.
            rd_rst = 1'b1;
            for (f = 0; f < 4; f = f + 1) begin
                expect_frame(8 + f, 4);
                send_frame(8 + f, 4);
            end
            for (f = 4; f < 10; f = f + 1)
                send_frame(8 + f, 4);
            rd_rst = 1'b0;
            repeat (2) @(posedge rd_clk);

            wait_for_expected_output(2000);
        end
    endtask

    task run_desc_full_test;
        integer f;
        begin
            $display("TEST: descriptor-full drops later one-byte frames");
            wr_half_period_ns = 4;
            rd_half_period_ns = 4;
            clear_expected();
            apply_reset();

            // Hold the read domain in reset so descriptor occupancy can reach MAX_FRAMES.
            rd_rst = 1'b1;
            for (f = 0; f < MAX_FRAMES; f = f + 1) begin
                expect_frame(64 + f, 1);
                send_frame(64 + f, 1);
            end
            for (f = MAX_FRAMES; f < MAX_FRAMES + 6; f = f + 1)
                send_frame(64 + f, 1);
            rd_rst = 1'b0;
            repeat (2) @(posedge rd_clk);

            wait_for_expected_output(2000);
        end
    endtask

    task run_wr_drop_test;
        begin
            $display("TEST: wr_drop discards frames with bad CRC");
            wr_half_period_ns = 4;
            rd_half_period_ns = 4;
            clear_expected();
            apply_reset();

            // Good frame, then dropped frame, then good frame.
            expect_frame(0, 5);
            send_frame(0, 5);
            send_dropped_frame(1, 4);
            expect_frame(2, 3);
            send_frame(2, 3);

            wait_for_expected_output(2000);
        end
    endtask

    task run_backpressure_test;
        reg [7:0] stalled_data;
        reg       stalled_last;
        integer   i;
        begin
            $display("TEST: read-side backpressure holds data stable");
            wr_half_period_ns = 4;
            rd_half_period_ns = 4;
            clear_expected();
            apply_reset();

            expect_frame(10, 6);

            fork
                send_frame(10, 6);
                begin
                    while (observed_count < 2)
                        @(posedge rd_clk);

                    while (!rd_valid)
                        @(posedge rd_clk);

                    @(negedge rd_clk);
                    stalled_data = rd_data;
                    stalled_last = rd_last;
                    rd_ready = 1'b0;

                    repeat (4) begin
                        @(posedge rd_clk);
                        if (!rd_valid) begin
                            $display("FAIL: rd_valid dropped during backpressure at t=%0t", $time);
                            error_count = error_count + 1;
                        end
                        if (rd_data !== stalled_data) begin
                            $display("FAIL: rd_data changed during backpressure exp=0x%02x got=0x%02x at t=%0t",
                                     stalled_data, rd_data, $time);
                            error_count = error_count + 1;
                        end
                        if (rd_last !== stalled_last) begin
                            $display("FAIL: rd_last changed during backpressure exp=%0d got=%0d at t=%0t",
                                     stalled_last, rd_last, $time);
                            error_count = error_count + 1;
                        end
                    end

                    @(negedge rd_clk);
                    rd_ready = 1'b1;
                end
            join

            wait_for_expected_output(2000);
        end
    endtask

    initial begin
        run_same_clock_test();
        run_dual_clock_test();
        run_payload_full_test();
        run_desc_full_test();
        run_wr_drop_test();
        run_backpressure_test();

        if (error_count != 0) begin
            $fatal(1, "tb_async_frame_fifo failed with %0d error(s)", error_count);
        end

        $display("PASS: tb_async_frame_fifo");
        $finish;
    end

    initial begin
        #500000;
        $fatal(1, "tb_async_frame_fifo timed out");
    end
endmodule

`default_nettype wire
