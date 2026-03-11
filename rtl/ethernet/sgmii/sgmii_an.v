// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright (c) 2026 Youssef Boukenken

// SGMII link policy (rx_clk domain).
//
// Watches config words from `sgmii_rx` and drives two policy flags:
// - `an_config_seen` output is set after the first valid config word from peer.
// - `link_up` output is set after a short holdoff once config is seen.
//
// While link is up, this block monitors comma activity and repeated valid
// config words (peer restart behavior). If either check fails, link state is
// dropped and negotiation state restarts.

module sgmii_an (
    input  wire        rx_clk,
    input  wire        rx_rst,
    input  wire [7:0]  rx_data,
    input  wire        rx_k,
    input  wire [15:0] rx_config_reg,
    input  wire        rx_config_new,

    output reg         an_config_seen,
    output reg         link_up
);

    localparam SGMII_CFG_BIT_VALID = 0;

    // 1ms at 125MHz (SGMII spec; Clause 37 uses 10ms)
    localparam [16:0] AN_LINK_TIMER = 17'd125_000;

    // bit 22 = ~34ms at 125MHz (2^22 / 125e6)
    localparam COMMA_WDT_BIT = 22;

    // bit 20 = 2^20 / 125e6 = ~8.4ms
    localparam LINK_GRACE_BIT = 20;

    localparam [7:0] K28_5 = 8'hBC;
    localparam [7:0] K27_7 = 8'hFB;

    reg [16:0] an_link_timer;
    reg [22:0] comma_watchdog;
    reg [LINK_GRACE_BIT:0] link_grace_timer;
    reg [1:0]  linkup_config_cnt;

    wire link_grace_expired = link_grace_timer[LINK_GRACE_BIT];
    wire an_restart_from_peer = (linkup_config_cnt == 2'd3);

    always @(posedge rx_clk) begin
        if (rx_rst || !link_up)
            comma_watchdog <= 23'd0;
        else if (rx_k && rx_data == K28_5)
            comma_watchdog <= 23'd0;
        else
            comma_watchdog <= comma_watchdog + 1'b1;
    end

    always @(posedge rx_clk) begin
        if (rx_rst || !link_up)
            link_grace_timer <= {(LINK_GRACE_BIT+1){1'b0}};
        else if (!link_grace_timer[LINK_GRACE_BIT])
            link_grace_timer <= link_grace_timer + 1'b1;
    end

    always @(posedge rx_clk) begin
        if (rx_rst || !link_up || !link_grace_expired)
            linkup_config_cnt <= 2'd0;
        else if (rx_config_new && rx_config_reg[SGMII_CFG_BIT_VALID])
            linkup_config_cnt <= (linkup_config_cnt < 2'd3) ? linkup_config_cnt + 1'b1 : linkup_config_cnt;
        else if (rx_k && rx_data == K27_7)
            linkup_config_cnt <= 2'd0;
    end

    always @(posedge rx_clk) begin
        if (rx_rst) begin
            an_config_seen <= 1'b0;
            an_link_timer  <= 17'd0;
            link_up        <= 1'b0;
        end else if (!an_config_seen) begin
            if (rx_config_new && rx_config_reg[SGMII_CFG_BIT_VALID])
                an_config_seen <= 1'b1;
        end else if (!link_up) begin
            if (an_link_timer < AN_LINK_TIMER)
                an_link_timer <= an_link_timer + 1'b1;
            else
                link_up <= 1'b1;
        end else begin
            if (comma_watchdog[COMMA_WDT_BIT] || an_restart_from_peer) begin
                an_config_seen <= 1'b0;
                an_link_timer  <= 17'd0;
                link_up        <= 1'b0;
            end
        end
    end

endmodule
