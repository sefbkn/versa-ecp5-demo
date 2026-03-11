// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright (c) 2026 Youssef Boukenken

module uart_mmio (
    input  wire       clk,
    input  wire       rst,
    input  wire [1:0] bus_reg,
    input  wire [1:0] read_reg,
    input  wire       bus_write,
    input  wire       bus_read,
    input  wire [31:0] wdata,
    input  wire       uart_rx_pin,
    output wire       uart_tx_pin,
    output reg  [31:0] rdata
);

    localparam [1:0] REG_STATUS = 2'b00;
    localparam [1:0] REG_TX_DATA = 2'b01;
    localparam [1:0] REG_RX_DATA = 2'b10;
    localparam [1:0] REG_RX_VALID = 2'b11;

    reg [7:0] uart_tx_data;
    reg       uart_tx_valid;
    reg [7:0] uart_tx_pending_data;
    reg       uart_tx_pending_valid;
    wire      uart_tx_ready;

    wire [7:0] uart_rx_data;
    wire       uart_rx_data_valid;

    reg [7:0] rx_latched_data;
    reg       rx_latched_valid;

    wire uart_write_tx = bus_write && (bus_reg == REG_TX_DATA);

    uart_tx u_uart_tx (
        .clk       (clk),
        .rst       (rst),
        .data      (uart_tx_data),
        .data_valid(uart_tx_valid),
        .tx_pin    (uart_tx_pin),
        .ready     (uart_tx_ready)
    );

    uart_rx u_uart_rx (
        .clk       (clk),
        .rst       (rst),
        .rx_pin    (uart_rx_pin),
        .data      (uart_rx_data),
        .data_valid(uart_rx_data_valid)
    );

    always @(posedge clk) begin
        if (rst) begin
            uart_tx_valid <= 1'b0;
            uart_tx_data <= 8'd0;
            uart_tx_pending_data <= 8'd0;
            uart_tx_pending_valid <= 1'b0;
            rx_latched_data <= 8'd0;
            rx_latched_valid <= 1'b0;
        end else begin
            uart_tx_valid <= 1'b0;

            if (uart_tx_pending_valid && uart_tx_ready) begin
                uart_tx_data  <= uart_tx_pending_data;
                uart_tx_valid <= 1'b1;
                if (uart_write_tx) begin
                    uart_tx_pending_data  <= wdata[7:0];
                    uart_tx_pending_valid <= 1'b1;
                end else begin
                    uart_tx_pending_valid <= 1'b0;
                end
            end else if (uart_write_tx) begin
                if (uart_tx_ready && !uart_tx_pending_valid) begin
                    uart_tx_data  <= wdata[7:0];
                    uart_tx_valid <= 1'b1;
                end else if (!uart_tx_pending_valid) begin
                    uart_tx_pending_data  <= wdata[7:0];
                    uart_tx_pending_valid <= 1'b1;
                end
            end

            if (bus_read && (bus_reg == REG_RX_DATA)) begin
                if (uart_rx_data_valid) begin
                    rx_latched_data  <= uart_rx_data;
                    rx_latched_valid <= 1'b1;
                end else begin
                    rx_latched_valid <= 1'b0;
                end
            end else if (uart_rx_data_valid && !rx_latched_valid) begin
                rx_latched_data  <= uart_rx_data;
                rx_latched_valid <= 1'b1;
            end
        end
    end

    always @(*) begin
        case (read_reg)
            REG_STATUS: rdata = {31'd0, !uart_tx_pending_valid};
            REG_TX_DATA: rdata = 32'd0;
            REG_RX_DATA: rdata = {24'd0, rx_latched_data};
            REG_RX_VALID: rdata = {31'd0, rx_latched_valid};
            default: rdata = 32'd0;
        endcase
    end

endmodule
