// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright (c) 2026 Youssef Boukenken

// IEEE 802.3 Clause 22 MDIO read/write controller
//
// Frame format
//   [63:32] Preamble    32x 1-bits
//   [31:30] Start       2'b01
//   [29:28] Opcode      2'b01=write, 2'b10=read
//   [27:23] PHY address 5 bits
//   [22:18] Reg address 5 bits
//   [17:16] Turnaround  2'b10 (write) or Z+0 (read)
//   [15:0]  Data        16 bits
//
// Clocked directly by sys_clk.
// MDC is generated internally from a clock-enable divider so the MDIO logic
// stays in one clock domain.

module mdio_master (
    input  wire        clk,
    input  wire        rst,

    // Command interface
    input  wire        cmd_valid,
    output reg         cmd_ready,
    input  wire        cmd_write,    // 1 = write, 0 = read
    input  wire [4:0]  cmd_phyad,
    input  wire [4:0]  cmd_reg_addr,
    input  wire [15:0] cmd_wdata,
    output reg  [15:0] cmd_rdata,
    output reg         cmd_done,

    // MDIO pins
    output reg         mdc,
    inout  wire        mdio
);

    // Advance the MDIO phase machine once per MDC half-period.
    // With a 100 MHz input clock, 40 cycles yields a 1.25 MHz MDC.
    localparam integer MDC_HALF_PERIOD_CYCLES = 16'd40;

    // Frame shift register
    // Clause 22 frame: 32-bit preamble + 2 ST + 2 OP + 5 PHYAD + 5 REG_ADDR + 2 TA + 16 DATA = 64 bits
    reg [63:0] shift_reg;
    reg [6:0]  bit_cnt;
    reg [15:0] mdc_div_ctr;
    reg        mdio_o_r;
    reg        mdio_oe_r;
    wire       mdio_i;

    localparam [1:0]
        S_IDLE  = 2'd0,
        S_SHIFT = 2'd1,
        S_DONE  = 2'd2;

    // Bit positions within the 64-bit MDIO frame
    localparam TA_BIT     = 46;  // turnaround starts at bit 46
    localparam DATA_START = 48;  // read data starts at bit 48
    localparam FRAME_END  = 64;  // total frame length

    reg [1:0] state;
    reg       is_write;
    reg       phase;  // 0 = falling edge (drive/shift), 1 = rising edge (sample)

    BB mdio_bb (
        .I (mdio_o_r),
        .T (~mdio_oe_r),
        .O (mdio_i),
        .B (mdio)
    );

    always @(posedge clk) begin
        if (rst) begin
            mdc      <= 1'b0;
            state    <= S_IDLE;
            cmd_ready <= 1'b1;
            cmd_done  <= 1'b0;
            mdio_o_r <= 1'b1;
            mdio_oe_r <= 1'b0;
            bit_cnt  <= 7'd0;
            mdc_div_ctr <= 16'd0;
            cmd_rdata <= 16'd0;
            shift_reg <= 64'd0;
            is_write  <= 1'b0;
            phase     <= 1'b0;
        end else begin
            cmd_done <= 1'b0;

            case (state)
                S_IDLE: begin
                    mdc     <= 1'b0;
                    mdio_oe_r <= 1'b0;
                    mdio_o_r  <= 1'b1;
                    mdc_div_ctr <= 16'd0;
                    if (cmd_valid && cmd_ready) begin
                        cmd_ready <= 1'b0;
                        is_write  <= cmd_write;
                        cmd_rdata <= 16'd0;
                        if (cmd_write) begin
                            shift_reg <= {
                                32'hFFFF_FFFF,   // preamble
                                2'b01,           // start of frame
                                2'b01,           // op = write
                                cmd_phyad,
                                cmd_reg_addr,
                                2'b10,           // turnaround (write)
                                cmd_wdata
                            };
                        end else begin
                            shift_reg <= {
                                32'hFFFF_FFFF,   // preamble
                                2'b01,           // start of frame
                                2'b10,           // op = read
                                cmd_phyad,
                                cmd_reg_addr,
                                2'b00,           // turnaround (read: release bus)
                                16'h0000
                            };
                        end
                        bit_cnt <= 7'd0;
                        phase   <= 1'b0;
                        state   <= S_SHIFT;
                    end
                end

                S_SHIFT: begin
                    if (mdc_div_ctr == (MDC_HALF_PERIOD_CYCLES - 1)) begin
                        mdc_div_ctr <= 16'd0;

                        if (!phase) begin
                            // Phase 0: hold MDC low, drive MDIO, advance bit
                            mdc <= 1'b0;
                            if (bit_cnt < FRAME_END) begin
                                if (!is_write && bit_cnt >= TA_BIT) begin
                                    mdio_oe_r <= 1'b0;
                                end else begin
                                    mdio_oe_r <= 1'b1;
                                    mdio_o_r  <= shift_reg[63];
                                end
                                shift_reg <= {shift_reg[62:0], 1'b0};
                                bit_cnt   <= bit_cnt + 7'd1;
                            end else begin
                                mdio_oe_r <= 1'b0;
                                mdio_o_r  <= 1'b1;
                                state   <= S_DONE;
                            end
                            phase <= 1'b1;
                        end else begin
                            // Phase 1: raise MDC and sample MDIO for reads
                            mdc <= 1'b1;
                            if (!is_write && bit_cnt > DATA_START && bit_cnt <= FRAME_END) begin
                                cmd_rdata <= {cmd_rdata[14:0], mdio_i};
                            end
                            phase <= 1'b0;
                        end
                    end else begin
                        mdc_div_ctr <= mdc_div_ctr + 16'd1;
                    end
                end

                S_DONE: begin
                    mdc       <= 1'b0;
                    mdc_div_ctr <= 16'd0;
                    cmd_done  <= 1'b1;
                    cmd_ready <= 1'b1;
                    state     <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
