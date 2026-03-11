// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright (c) 2026 Youssef Boukenken

// Per-PHY bring-up block for the board PHY management path.
// Handles reset sequencing, optional mode programming, and MDIO handoff.
// Runs entirely on sys_clk.
//
// Sequence:
//   1. Hardware reset: assert phy_resetn low for 200ms, then release + wait 200ms
//   2. Optional mode init (ENABLE_MODE_INIT=1):
//      program 88E1512 interface mode via one logical paged MDIO write:
//      page 18, reg 20 = MODE_SGMII ? 0x8001 : 0x8000
//      - 0x8001: MODE=001 (SGMII-to-Copper) + SW reset
//      - 0x8000: MODE=000 (RGMII-to-Copper) + SW reset
//      then wait 100ms for software reset to complete
//   3. Assert init_done, hand control to external MDIO command port.
//
// When ENABLE_MODE_INIT=0, step 2 is skipped and init_done asserts right after
// the hardware reset timing window.
//
module phy_init #(
    parameter [4:0] PHY_ADDR = 5'd0,  // MDIO PHY address (set by CONFIG strap)
    parameter ENABLE_MODE_INIT = 1,   // 1 = run mode register init sequence
    parameter MODE_SGMII = 1          // 1 = SGMII, 0 = RGMII
) (
    input  wire        clk,
    input  wire        rst,

    // PHY reset pin
    output reg         phy_resetn,

    // MDIO interface
    output wire        mdc,
    inout  wire        mdio,

    // Status
    output reg         init_done,

    // External MDIO command port (clk domain)
    // ext_cmd_data = {write, page, reg_addr, wdata}
    input  wire        ext_cmd_valid,
    output wire        ext_cmd_ready,
    input  wire [26:0] ext_cmd_data,
    output wire [15:0] ext_cmd_rdata,
    output wire        ext_cmd_done
);

    // Reset timing (clk domain, 100 MHz sys_clk)
    localparam integer RST_ASSERT_CYCLES = 32'd20000000; // 200 ms
    localparam integer RST_WAIT_CYCLES   = 32'd20000000; // 200 ms
    localparam integer SGMII_WAIT_CYCLES = 32'd10000000; // 100 ms

    // 88E1512 MDIO register values
    localparam [4:0]  SGMII_PAGE        = 5'd18;     // Page 18: SGMII/fiber registers
    localparam [15:0] SGMII_MODE_SWRST  = 16'h8001;  // MODE[2:0]=001 (SGMII to Copper) + bit15 SW reset
    localparam [15:0] RGMII_MODE_SWRST  = 16'h8000;  // MODE[2:0]=000 (RGMII to Copper) + bit15 SW reset
    localparam [4:0]  REG_MODE_CONTROL  = 5'd20;     // General control register 1 (page 18)

    // Main state machine
    localparam [3:0]
        S_HW_RESET_ASSERT = 4'd0,   // Assert phy_resetn low
        S_HW_RESET_WAIT   = 4'd1,   // Wait after releasing reset
        S_MODE_REG20      = 4'd2,   // Write page18/reg20 (mode + SW reset)
        S_MODE_REG20_W    = 4'd3,   // Wait for MDIO complete
        S_MODE_WAIT       = 4'd4,   // Wait 100ms for SW reset
        S_DONE            = 4'd5;   // Init done, external commands enabled

    reg [3:0]  state;
    reg [31:0] timer;

    // MDIO command interface — muxed between internal init and external
    wire        bus_cmd_valid;
    wire        bus_cmd_ready;
    wire [26:0] bus_cmd_data;
    wire [15:0] bus_cmd_rdata;
    wire        bus_cmd_done;

    // Internal init command signals
    reg         int_cmd_valid;
    reg  [26:0] int_cmd_data;

    mdio_paged #(
        .PHY_ADDR(PHY_ADDR)
    ) u_mdio (
        .clk       (clk),
        .rst       (state == S_HW_RESET_ASSERT || state == S_HW_RESET_WAIT),
        .cmd_valid (bus_cmd_valid),
        .cmd_ready (bus_cmd_ready),
        .cmd_data  (bus_cmd_data),
        .cmd_rdata (bus_cmd_rdata),
        .cmd_done  (bus_cmd_done),
        .mdc       (mdc),
        .mdio      (mdio)
    );

    // Mux: internal init takes priority until init_done
    assign bus_cmd_valid = init_done ? ext_cmd_valid : int_cmd_valid;
    assign bus_cmd_data  = init_done ? ext_cmd_data : int_cmd_data;

    assign ext_cmd_ready = init_done ? bus_cmd_ready : 1'b0;
    assign ext_cmd_rdata = bus_cmd_rdata;
    assign ext_cmd_done  = init_done ? bus_cmd_done : 1'b0;

    always @(posedge clk) begin
        if (rst) begin
            state         <= S_HW_RESET_ASSERT;
            timer         <= 32'd0;
            phy_resetn    <= 1'b0;
            init_done     <= 1'b0;
            int_cmd_valid <= 1'b0;
            int_cmd_data  <= 27'd0;
        end else begin
            case (state)
                S_HW_RESET_ASSERT: begin
                    phy_resetn <= 1'b0;
                    timer <= timer + 32'd1;
                    if (timer == RST_ASSERT_CYCLES) begin
                        phy_resetn <= 1'b1;
                        timer      <= 32'd0;
                        state      <= S_HW_RESET_WAIT;
                    end
                end

                S_HW_RESET_WAIT: begin
                    timer <= timer + 32'd1;
                    if (timer == RST_WAIT_CYCLES) begin
                        timer <= 32'd0;
                        state <= ENABLE_MODE_INIT ? S_MODE_REG20 : S_DONE;
                    end
                end

                // Mode init: write page 18 reg 20 (mode + SW reset)
                S_MODE_REG20: begin
                    int_cmd_valid <= 1'b1;
                    int_cmd_data <= {
                        1'b1,
                        SGMII_PAGE,
                        REG_MODE_CONTROL,
                        MODE_SGMII ? SGMII_MODE_SWRST : RGMII_MODE_SWRST
                    };
                    if (bus_cmd_ready && int_cmd_valid) begin
                        int_cmd_valid <= 1'b0;
                        state <= S_MODE_REG20_W;
                    end
                end

                S_MODE_REG20_W: begin
                    int_cmd_valid <= 1'b0;
                    if (bus_cmd_done) begin
                        timer <= 32'd0;
                        state <= S_MODE_WAIT;
                    end
                end

                // Wait 100ms for software reset to complete
                S_MODE_WAIT: begin
                    timer <= timer + 32'd1;
                    if (timer == SGMII_WAIT_CYCLES)
                        state <= S_DONE;
                end

                // Init complete
                S_DONE: begin
                    init_done <= 1'b1;
                end

                default: state <= S_HW_RESET_ASSERT;
            endcase
        end
    end

endmodule
