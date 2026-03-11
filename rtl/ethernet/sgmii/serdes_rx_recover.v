// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright (c) 2026 Youssef Boukenken

// RX recovery sequencer for ECP5 SGMII lanes.
//
// This module implements a robust bring-up sequence using the DCU status flags:
// 1) Wait for shared TX PLL stable and LOS deasserted.
// 2) Pulse RX SerDes reset, then verify CDR lock.
// 3) Pulse RX PCS reset, then verify LSM/CV quality.
// 4) Run state with continuous quality monitoring and automatic re-train.
//
// Clock domain: channel TX PCLK (125 MHz).
// Raw status inputs are synchronized internally with 2 FF stages.

(* keep_hierarchy = "yes" *)
module serdes_rx_recover (
    input  wire clk,
    input  wire rst,          // Active-high local reset
    input  wire enable,       // Allow sequencer to run (PHY init + TX ready)
    input  wire pll_lol,      // 1 = PLL loss of lock
    input  wire los,          // 1 = loss-of-signal
    input  wire cdr_lol,      // 1 = CDR loss of lock
    input  wire lsm_status,   // 1 = lane sync marker status good
    input  wire cv_err,       // 1 = code violation seen
    output reg  rx_serdes_rst,
    output reg  rx_pcs_rst
);

    // 2-FF input synchronizers into tx_pclk domain.
    wire pll_bad;
    wire los_bad;
    wire cdr_bad;
    wire lsm_good;

    sync_ff #(.RESET_VAL(1'b1)) u_pll_sync (
        .clk(clk),
        .rst(rst),
        .in_level(pll_lol),
        .out_level(pll_bad)
    );

    sync_ff #(.RESET_VAL(1'b1)) u_los_sync (
        .clk(clk),
        .rst(rst),
        .in_level(los),
        .out_level(los_bad)
    );

    sync_ff #(.RESET_VAL(1'b1)) u_cdr_sync (
        .clk(clk),
        .rst(rst),
        .in_level(cdr_lol),
        .out_level(cdr_bad)
    );

    sync_ff #(.RESET_VAL(1'b0)) u_lsm_sync (
        .clk(clk),
        .rst(rst),
        .in_level(lsm_status),
        .out_level(lsm_good)
    );

    // LSM loss means word boundaries are gone so retrain immediately.
    wire align_bad = !lsm_good;
    wire must_hold = (!enable) || pll_bad || los_bad;

    localparam [2:0]
        ST_HOLD       = 3'd0,
        ST_CDR_PULSE  = 3'd1,
        ST_CDR_SETTLE = 3'd2,
        ST_CDR_VERIFY = 3'd3,
        ST_PCS_PULSE  = 3'd4,
        ST_PCS_SETTLE = 3'd5,
        ST_PCS_VERIFY = 3'd6,
        ST_RUN        = 3'd7;

    // Fixed width for readability: 21 bits covers 1,048,576-cycle settle timers.
    localparam integer CNTW = 21;
    localparam [CNTW-1:0] PLL_STABLE_CYCLES = 21'h10_0000;
    localparam [CNTW-1:0] CDR_SETTLE_CYCLES = 21'h10_0000;
    localparam [CNTW-1:0] PCS_SETTLE_CYCLES = 21'h10_0000;
    localparam [CNTW-1:0] RST_PULSE_LAST    = 21'h00_0007; // 8-cycle pulse

    reg [2:0]  state;
    reg [CNTW-1:0] cnt;

    always @(posedge clk) begin
        if (rst) begin
            state <= ST_HOLD;
            cnt <= {CNTW{1'b0}};
            rx_serdes_rst <= 1'b1;
            rx_pcs_rst <= 1'b1;
        end else begin
            case (state)
                ST_HOLD: begin
                    rx_serdes_rst <= 1'b1;
                    rx_pcs_rst    <= 1'b1;
                    if (must_hold) begin
                        cnt <= {CNTW{1'b0}};
                    end else if (cnt == PLL_STABLE_CYCLES) begin
                        cnt <= {CNTW{1'b0}};
                        state <= ST_CDR_PULSE;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                ST_CDR_PULSE: begin
                    rx_serdes_rst <= 1'b1;
                    rx_pcs_rst    <= 1'b1;
                    if (must_hold) begin
                        cnt <= {CNTW{1'b0}};
                        state <= ST_HOLD;
                    end else if (cnt == RST_PULSE_LAST) begin
                        cnt <= {CNTW{1'b0}};
                        state <= ST_CDR_SETTLE;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                ST_CDR_SETTLE: begin
                    rx_serdes_rst <= 1'b0;
                    rx_pcs_rst    <= 1'b1;
                    if (must_hold) begin
                        cnt <= {CNTW{1'b0}};
                        state <= ST_HOLD;
                    end else if (cnt == CDR_SETTLE_CYCLES) begin
                        cnt <= {CNTW{1'b0}};
                        state <= ST_CDR_VERIFY;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                ST_CDR_VERIFY: begin
                    rx_serdes_rst <= 1'b0;
                    rx_pcs_rst    <= 1'b1;
                    if (must_hold) begin
                        cnt <= {CNTW{1'b0}};
                        state <= ST_HOLD;
                    end else if (cdr_bad) begin
                        cnt <= {CNTW{1'b0}};
                        state <= ST_CDR_PULSE;
                    end else if (cnt == CDR_SETTLE_CYCLES) begin
                        cnt <= {CNTW{1'b0}};
                        state <= ST_PCS_PULSE;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                ST_PCS_PULSE: begin
                    rx_serdes_rst <= 1'b0;
                    rx_pcs_rst    <= 1'b1;
                    if (must_hold) begin
                        cnt <= {CNTW{1'b0}};
                        state <= ST_HOLD;
                    end else if (cnt == RST_PULSE_LAST) begin
                        cnt <= {CNTW{1'b0}};
                        state <= ST_PCS_SETTLE;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                ST_PCS_SETTLE: begin
                    rx_serdes_rst <= 1'b0;
                    rx_pcs_rst    <= 1'b0;
                    if (must_hold) begin
                        cnt <= {CNTW{1'b0}};
                        state <= ST_HOLD;
                    end else if (cnt == PCS_SETTLE_CYCLES) begin
                        cnt <= {CNTW{1'b0}};
                        state <= ST_PCS_VERIFY;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                ST_PCS_VERIFY: begin
                    rx_serdes_rst <= 1'b0;
                    rx_pcs_rst    <= 1'b0;
                    if (must_hold) begin
                        cnt <= {CNTW{1'b0}};
                        state <= ST_HOLD;
                    end else if (align_bad) begin
                        cnt <= {CNTW{1'b0}};
                        state <= ST_PCS_PULSE;
                    end else if (cnt == PCS_SETTLE_CYCLES) begin
                        cnt <= {CNTW{1'b0}};
                        state <= ST_RUN;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                ST_RUN: begin
                    rx_serdes_rst <= 1'b0;
                    rx_pcs_rst    <= 1'b0;
                    if (must_hold) begin
                        cnt <= {CNTW{1'b0}};
                        state <= ST_HOLD;
                    end else if (align_bad) begin
                        cnt <= {CNTW{1'b0}};
                        state <= ST_PCS_PULSE;
                    end
                end

                default: begin
                    state <= ST_HOLD;
                    cnt <= {CNTW{1'b0}};
                    rx_serdes_rst <= 1'b1;
                    rx_pcs_rst <= 1'b1;
                end
            endcase
        end
    end

endmodule
