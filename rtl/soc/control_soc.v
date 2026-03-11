// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright (c) 2026 Youssef Boukenken

// Minimal control-plane SoC:
// - VexRiscv core
// - ROM/RAM
// - UART MMIO
// - MDIO request bridge into ethernet_top
module control_soc #(
    parameter INIT_FILE = "build/firmware/firmware.hex"
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        uart_rx_pin,
    output wire        uart_tx_pin,
    output wire        ctrl_req_valid,
    input  wire        ctrl_req_ready,
    output wire [31:0] ctrl_req_data,
    input  wire        ctrl_rsp_valid,
    input  wire [31:0] ctrl_rsp_data
);

    // This MMIO map is mirrored by firmware/soc_map.rs.
    localparam [31:0] ROM_SIZE_BYTES = 32'd16384;
    localparam [31:0] RAM_BASE       = 32'h1000_0000;
    localparam [31:0] RAM_SIZE_BYTES = 32'd8192;
    localparam [31:0] UART_BASE      = 32'h2000_0000;
    localparam [31:0] MDIO_BASE      = 32'h3000_0000;
    localparam ROM_ADDR_W = $clog2(ROM_SIZE_BYTES / 4);
    localparam RAM_ADDR_W = $clog2(RAM_SIZE_BYTES / 4);
    localparam [2:0]  TGT_NONE       = 3'd0;
    localparam [2:0]  TGT_ROM        = 3'd1;
    localparam [2:0]  TGT_RAM        = 3'd2;
    localparam [2:0]  TGT_UART       = 3'd3;
    localparam [2:0]  TGT_MDIO       = 3'd4;

    // Imported VexRiscv CPU core
    wire        ibus_cmd_valid;
    wire        ibus_cmd_ready;
    wire [31:0] ibus_cmd_pc;
    wire        ibus_rsp_valid;
    wire        ibus_rsp_error;
    wire [31:0] ibus_rsp_inst;

    wire        dbus_cmd_valid;
    wire        dbus_cmd_ready;
    wire        dbus_cmd_wr;
    wire [3:0]  dbus_cmd_mask;
    wire [31:0] dbus_cmd_address;
    wire [31:0] dbus_cmd_data;
    wire        dbus_rsp_ready;
    wire        dbus_rsp_error;
    reg  [31:0] dbus_rsp_data;

    VexRiscv u_cpu (
        .clk                  (clk),
        .reset                (rst),
        .iBus_cmd_valid       (ibus_cmd_valid),
        .iBus_cmd_ready       (ibus_cmd_ready),
        .iBus_cmd_payload_pc  (ibus_cmd_pc),
        .iBus_rsp_valid       (ibus_rsp_valid),
        .iBus_rsp_payload_error(ibus_rsp_error),
        .iBus_rsp_payload_inst(ibus_rsp_inst),
        .dBus_cmd_valid       (dbus_cmd_valid),
        .dBus_cmd_ready       (dbus_cmd_ready),
        .dBus_cmd_payload_wr  (dbus_cmd_wr),
        .dBus_cmd_payload_mask(dbus_cmd_mask),
        .dBus_cmd_payload_address(dbus_cmd_address),
        .dBus_cmd_payload_data(dbus_cmd_data),
        .dBus_cmd_payload_size(),
        .dBus_rsp_ready       (dbus_rsp_ready),
        .dBus_rsp_error       (dbus_rsp_error),
        .dBus_rsp_data        (dbus_rsp_data),
        .timerInterrupt       (1'b0),
        .externalInterrupt    (1'b0),
        .softwareInterrupt    (1'b0)
    );

    // Instruction ROM (16KB)
    wire [31:0] instr_rdata;
    wire [31:0] rom_rdata;

    reg                    ibus_pending;
    reg                    ibus_ack;
    reg                    ibus_err;
    reg [ROM_ADDR_W-1:0]   ibus_addr_held;
    wire       ibus_sel_rom = (ibus_cmd_pc < ROM_SIZE_BYTES);

    always @(posedge clk) begin
        if (rst) begin
            ibus_addr_held <= {ROM_ADDR_W{1'b0}};
            ibus_pending <= 1'b0;
            ibus_ack <= 1'b0;
            ibus_err <= 1'b0;
        end else begin
            if (ibus_cmd_valid && ibus_cmd_ready) begin
                ibus_addr_held <= ibus_sel_rom ? ibus_cmd_pc[ROM_ADDR_W+1:2] : {ROM_ADDR_W{1'b0}};
                ibus_err       <= !ibus_sel_rom;
                ibus_pending <= 1'b1;
            end else begin
                ibus_pending <= 1'b0;
            end
            ibus_ack <= ibus_pending;
        end
    end

    assign ibus_cmd_ready = !ibus_pending && !ibus_ack;
    assign ibus_rsp_valid = ibus_ack;
    assign ibus_rsp_error = ibus_ack && ibus_err;
    assign ibus_rsp_inst  = ibus_err ? 32'h0000_0013 : instr_rdata;

    // Data bus (1-cycle response)
    reg        dbus_rsp_valid_r;
    reg        dbus_rsp_error_r;
    reg [2:0]  cmd_target;
    reg [2:0]  rsp_target;
    reg [13:0] rsp_word_addr;
    reg [1:0]  rsp_reg;
    wire [1:0] dbus_cmd_reg = dbus_cmd_address[3:2];

    wire dbus_fire = dbus_cmd_valid && !dbus_rsp_valid_r;

    always @(*) begin
        if (dbus_cmd_address < ROM_SIZE_BYTES)
            cmd_target = TGT_ROM;
        else if ((dbus_cmd_address >= RAM_BASE) &&
                 (dbus_cmd_address < (RAM_BASE + RAM_SIZE_BYTES)))
            cmd_target = TGT_RAM;
        else if (dbus_cmd_address[31:4] == UART_BASE[31:4])
            cmd_target = TGT_UART;
        else if (dbus_cmd_address[31:4] == MDIO_BASE[31:4])
            cmd_target = TGT_MDIO;
        else
            cmd_target = TGT_NONE;
    end

    always @(posedge clk) begin
        if (rst) begin
            dbus_rsp_valid_r <= 1'b0;
            dbus_rsp_error_r <= 1'b0;
            rsp_target       <= TGT_NONE;
            rsp_word_addr    <= 14'd0;
            rsp_reg          <= 2'd0;
        end else begin
            dbus_rsp_valid_r <= dbus_fire;
            dbus_rsp_error_r <= dbus_fire &&
                                ((cmd_target == TGT_NONE) ||
                                 ((cmd_target == TGT_ROM) && dbus_cmd_wr));

            if (dbus_fire) begin
                rsp_target    <= cmd_target;
                rsp_word_addr <= dbus_cmd_address[15:2];
                rsp_reg       <= dbus_cmd_reg;
            end
        end
    end

    assign dbus_cmd_ready = !dbus_rsp_valid_r;
    assign dbus_rsp_ready = dbus_rsp_valid_r;
    assign dbus_rsp_error = dbus_rsp_error_r;

    instr_rom #(
        .SIZE(ROM_SIZE_BYTES),
        .INIT_FILE(INIT_FILE)
    ) u_instr_rom (
        .clk    (clk),
        .addr_a (ibus_addr_held),
        .rdata_a(instr_rdata),
        .addr_b (dbus_fire ? (
            (cmd_target == TGT_ROM) ? dbus_cmd_address[ROM_ADDR_W+1:2] : {ROM_ADDR_W{1'b0}}
        ) : (
            (rsp_target == TGT_ROM) ? rsp_word_addr[ROM_ADDR_W-1:0] : {ROM_ADDR_W{1'b0}}
        )),
        .rdata_b(rom_rdata)
    );

    // RAM (8KB)
    wire [31:0] ram_rdata;

    data_ram #(
        .SIZE(RAM_SIZE_BYTES)
    ) u_data_ram (
        .clk  (clk),
        .addr ((dbus_fire && (cmd_target == TGT_RAM)) ? dbus_cmd_address[RAM_ADDR_W+1:2] :
               (rsp_target == TGT_RAM) ? rsp_word_addr[RAM_ADDR_W-1:0] :
               {RAM_ADDR_W{1'b0}}),
        .wdata(dbus_cmd_data),
        .we   ((dbus_fire && (cmd_target == TGT_RAM) && dbus_cmd_wr) ? dbus_cmd_mask : 4'b0),
        .rdata(ram_rdata)
    );

    // UART
    wire [31:0] uart_rdata;

    uart_mmio u_uart_mmio (
        .clk      (clk),
        .rst      (rst),
        .bus_reg  (dbus_cmd_reg),
        .read_reg (rsp_reg),
        .bus_write(dbus_fire && (cmd_target == TGT_UART) && dbus_cmd_wr),
        .bus_read (dbus_fire && (cmd_target == TGT_UART) && !dbus_cmd_wr),
        .wdata    (dbus_cmd_data),
        .uart_rx_pin(uart_rx_pin),
        .uart_tx_pin(uart_tx_pin),
        .rdata    (uart_rdata)
    );

    wire [31:0] mdio_rdata;

    mdio_mmio u_mdio_mmio (
        .clk         (clk),
        .rst         (rst),
        .bus_reg     (dbus_cmd_reg),
        .read_reg    (rsp_reg),
        .bus_write   (dbus_fire && (cmd_target == TGT_MDIO) && dbus_cmd_wr),
        .wdata       (dbus_cmd_data),
        .rdata       (mdio_rdata),
        .ctrl_req_valid(ctrl_req_valid),
        .ctrl_req_ready(ctrl_req_ready),
        .ctrl_req_data(ctrl_req_data),
        .ctrl_rsp_valid(ctrl_rsp_valid),
        .ctrl_rsp_data(ctrl_rsp_data)
    );

    always @(*) begin
        if (dbus_rsp_error_r)
            dbus_rsp_data = 32'd0;
        else begin
            case (rsp_target)
                TGT_RAM:  dbus_rsp_data = ram_rdata;
                TGT_ROM:  dbus_rsp_data = rom_rdata;
                TGT_UART: dbus_rsp_data = uart_rdata;
                TGT_MDIO: dbus_rsp_data = mdio_rdata;
                default:  dbus_rsp_data = 32'd0;
            endcase
        end
    end

endmodule
