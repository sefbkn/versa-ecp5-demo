// SPDX-License-Identifier: CERN-OHL-S-2.0
// Copyright (c) 2026 Youssef Boukenken

// Dual-channel ECP5 SERDES transceiver for 1.25 Gbps SGMII.
// DCU1: CH0 -> PHY1 (U14), CH1 -> PHY2 (U15).
//
// Reference clock: REFCLK_D1 (Y19/W20) from ispClock5406D (156.25 MHz).
// Line rate: 1.25 Gbps. GBE mode uses the DCUA 8b/10b datapath internally.
// TX bus packing: {12'b0, disp, 2'b0, K, data[7:0]}
// RX bus packing: data = [7:0], K = [8]

module sgmii_dcu (
    input  wire        dcu_rst, // DCU-level reset (sys_clk domain)
    input  wire        both_phys_ready, // gates RX reset release (sys_clk domain)

    // Channel 0 (PHY1) fabric interface — 8-bit+K (GBE mode)
    output wire        ch0_rx_pclk,      // RX recovered clock (125 MHz)
    output wire        ch0_tx_pclk,      // TX PCS clock (125 MHz)
    output reg  [7:0]  ch0_rx_data,      // RX data (pipelined, rx_pclk domain)
    output reg         ch0_rx_k,         // RX K flag (pipelined)
    output reg         ch0_rx_cv_err,    // RX code violation (pipelined)
    input  wire [7:0]  ch0_tx_data,      // TX data
    input  wire        ch0_tx_k,         // TX K flag
    input  wire        ch0_tx_disp,      // TX disparity control
    output wire        ch0_rx_rst,       // RX PCS reset (synchronized into rx_pclk)
    output wire        ch0_tx_rst,       // TX PCS reset (synchronized into tx_pclk)

    // Channel 1 (PHY2) fabric interface (identical)
    output wire        ch1_rx_pclk,
    output wire        ch1_tx_pclk,
    output reg  [7:0]  ch1_rx_data,
    output reg         ch1_rx_k,
    output reg         ch1_rx_cv_err,
    input  wire [7:0]  ch1_tx_data,
    input  wire        ch1_tx_k,
    input  wire        ch1_tx_disp,
    output wire        ch1_rx_rst,
    output wire        ch1_tx_rst
);

    // Internal wires for the 24-bit data buses
    wire [23:0] ch0_tx_d, ch0_rx_d;
    wire [23:0] ch1_tx_d, ch1_rx_d;

    // TX bus mapping (per TN1261 SERDES usage guide)
    // Bit 11 = disparity force, bit 8 = K flag, bits [7:0] = data
    assign ch0_tx_d = {12'b0, ch0_tx_disp, 2'b0, ch0_tx_k, ch0_tx_data};
    assign ch1_tx_d = {12'b0, ch1_tx_disp, 2'b0, ch1_tx_k, ch1_tx_data};

    // RX bus mapping — DCU decodes 8b/10b internally
    // Bits [7:0] = decoded data, bit [8] = K flag
    wire [7:0] ch0_rx_data_raw = ch0_rx_d[7:0];
    wire       ch0_rx_k_raw    = ch0_rx_d[8];
    wire       ch0_rx_cv_err_raw  = ch0_rx_d[10];
    wire       ch0_rx_los;
    wire       ch0_rx_cdr_lol;
    wire       ch0_lsm_status;

    wire [7:0] ch1_rx_data_raw = ch1_rx_d[7:0];
    wire       ch1_rx_k_raw    = ch1_rx_d[8];
    wire       ch1_rx_cv_err_raw  = ch1_rx_d[10];
    wire       ch1_rx_los;
    wire       ch1_rx_cdr_lol;
    wire       ch1_lsm_status;

    // Internal clock wires
    wire ch0_rx_pclk_int;
    wire ch0_tx_pclk_int;
    wire ch1_rx_pclk_int;
    wire ch1_tx_pclk_int;
    wire tx_pll_lol;

    assign ch0_rx_pclk = ch0_rx_pclk_int;
    assign ch0_tx_pclk = ch0_tx_pclk_int;
    assign ch1_rx_pclk = ch1_rx_pclk_int;
    assign ch1_tx_pclk = ch1_tx_pclk_int;

    // RX pipeline registers (one stage per channel)
    //
    // Break timing from DCU outputs to PCS logic.
    // rx_data/rx_k are registered here.
    always @(posedge ch0_rx_pclk_int) begin
        ch0_rx_data   <= ch0_rx_data_raw;
        ch0_rx_k      <= ch0_rx_k_raw;
        ch0_rx_cv_err <= ch0_rx_cv_err_raw;
    end

    always @(posedge ch1_rx_pclk_int) begin
        ch1_rx_data   <= ch1_rx_data_raw;
        ch1_rx_k      <= ch1_rx_k_raw;
        ch1_rx_cv_err <= ch1_rx_cv_err_raw;
    end

    // TX Reset FSM (tx_pclk domain)
    //
    // Sequence: assert TX resets -> release TX SERDES (D_FFC_TRST) ->
    //   wait PLL lock -> release TX PCS -> done.
    //
    // D_FFC_TRST must be explicitly sequenced for dual-channel operation;
    // it resets shared TX resources (PLL path, serializer state).
    //
    // tx_pll_lol is synchronous to tx_pclk (DCU output), no CDC needed.
    // dcu_rst and both_phys_ready are CDC'd from sys_clk into tx_pclk.

    // CDC dcu_rst into tx_pclk (async assert, sync deassert)
    wire dcu_rst_tx;
    sync_ff #(.RESET_VAL(1'b1)) u_dcu_rst_sync (
        .clk(ch0_tx_pclk_int),
        .rst(dcu_rst),
        .in_level(1'b0),
        .out_level(dcu_rst_tx)
    );

    // Settle timer bit position (~10us at 125 MHz)
    localparam RST_SETTLE_BIT = 10;

    localparam [1:0]
        RST_RELEASE_TRST = 2'd0,  // Release TX SERDES reset (D_FFC_TRST)
        RST_WAIT_PLL     = 2'd1,  // Wait for TX PLL lock
        RST_RELEASE_TX   = 2'd2,  // Release TX PCS lane resets
        RST_DONE         = 2'd3;

    reg [1:0]  rst_state;
    reg [23:0] rst_timer;
    reg        tx_serdes_rst;
    reg        tx_pcs_rst;

    always @(posedge ch0_tx_pclk_int) begin
        if (dcu_rst_tx) begin
            rst_state     <= RST_RELEASE_TRST;
            rst_timer     <= 24'd0;
            tx_serdes_rst <= 1'b1;
            tx_pcs_rst    <= 1'b1;
        end else begin
            case (rst_state)
                RST_RELEASE_TRST: begin
                    tx_serdes_rst <= 1'b0;
                    rst_timer <= rst_timer + 1;
                    if (rst_timer[RST_SETTLE_BIT]) begin
                        rst_timer <= 24'd0;
                        rst_state <= RST_WAIT_PLL;
                    end
                end

                RST_WAIT_PLL: begin
                    // tx_pll_lol is synchronous to tx_pclk — no CDC needed
                    if (!tx_pll_lol) begin
                        rst_timer <= 24'd0;
                        rst_state <= RST_RELEASE_TX;
                    end
                end

                RST_RELEASE_TX: begin
                    tx_pcs_rst <= 1'b0;
                    rst_timer <= rst_timer + 1;
                    if (rst_timer[RST_SETTLE_BIT]) begin
                        rst_timer <= 24'd0;
                        rst_state <= RST_DONE;
                    end
                end

                RST_DONE: begin
                    // TX path ready
                end

                default: rst_state <= RST_RELEASE_TRST;
            endcase
        end
    end

    wire tx_rst_done = (rst_state == RST_DONE);

    // RX reset release policy:
    // Hold RX SerDes and RX PCS in reset until:
    // 1) TX reset FSM reaches DONE
    // 2) both PHYs complete init
    //
    // Keep readiness synchronization per-channel so CH1 logic runs
    // in ch1_tx_pclk domain. tx_rst_done remains a shared CH0-owned
    // readiness source and is CDC'd into CH1.
    wire both_phys0_s1;
    sync_ff #(.RESET_VAL(1'b0)) u_both_phys0_sync (
        .clk(ch0_tx_pclk_int),
        .rst(dcu_rst_tx),
        .in_level(both_phys_ready),
        .out_level(both_phys0_s1)
    );

    wire both_phys1_s1;
    sync_ff #(.RESET_VAL(1'b0)) u_both_phys1_sync (
        .clk(ch1_tx_pclk_int),
        .rst(tx_pcs_rst),
        .in_level(both_phys_ready),
        .out_level(both_phys1_s1)
    );

    // tx_rst_done is generated in ch0_tx_pclk domain; CDC into ch1.
    wire tx_done1_s1;
    sync_ff #(.RESET_VAL(1'b0)) u_tx_done1_sync (
        .clk(ch1_tx_pclk_int),
        .rst(tx_pcs_rst),
        .in_level(tx_rst_done),
        .out_level(tx_done1_s1)
    );

    // Per-channel RX recovery sequencers
    wire ch0_rx_serdes_rst_int;
    wire ch0_rx_pcs_rst_int;
    wire ch1_rx_serdes_rst_int;
    wire ch1_rx_pcs_rst_int;

    wire ch0_rx_ready = tx_rst_done && both_phys0_s1;
    wire ch1_rx_ready = tx_done1_s1 && both_phys1_s1;

    serdes_rx_recover u_serdes_rx_recover_ch0 (
        .clk          (ch0_tx_pclk_int),
        .rst          (dcu_rst_tx),
        .enable       (ch0_rx_ready),
        .pll_lol      (tx_pll_lol),
        .los          (ch0_rx_los),
        .cdr_lol      (ch0_rx_cdr_lol),
        .lsm_status   (ch0_lsm_status),
        .cv_err       (ch0_rx_cv_err_raw),
        .rx_serdes_rst(ch0_rx_serdes_rst_int),
        .rx_pcs_rst   (ch0_rx_pcs_rst_int)
    );

    serdes_rx_recover u_serdes_rx_recover_ch1 (
        .clk          (ch1_tx_pclk_int),
        .rst          (tx_pcs_rst),
        .enable       (ch1_rx_ready),
        .pll_lol      (tx_pll_lol),
        .los          (ch1_rx_los),
        .cdr_lol      (ch1_rx_cdr_lol),
        .lsm_status   (ch1_lsm_status),
        .cv_err       (ch1_rx_cv_err_raw),
        .rx_serdes_rst(ch1_rx_serdes_rst_int),
        .rx_pcs_rst   (ch1_rx_pcs_rst_int)
    );

    // PCS reset synchronizers (async assert, sync deassert)
    //
    // TX PCS reset: tx_pcs_rst (tx_pclk) -> ch*_tx_pclk
    //   (registered locally for uniform reset fanout)
    // RX PCS reset: ch*_rx_pcs_rst (tx_pclk) -> ch*_rx_pclk

    // TX reset sync into tx_pclk domains
    sync_ff #(.RESET_VAL(1'b1)) u_ch0_tx_rst_sync (
        .clk(ch0_tx_pclk_int),
        .rst(tx_pcs_rst),
        .in_level(1'b0),
        .out_level(ch0_tx_rst)
    );

    sync_ff #(.RESET_VAL(1'b1)) u_ch1_tx_rst_sync (
        .clk(ch1_tx_pclk_int),
        .rst(tx_pcs_rst),
        .in_level(1'b0),
        .out_level(ch1_tx_rst)
    );

    // RX reset sync into rx_pclk domains
    sync_ff #(.RESET_VAL(1'b1)) u_ch0_rx_rst_sync (
        .clk(ch0_rx_pclk_int),
        .rst(ch0_rx_pcs_rst_int),
        .in_level(1'b0),
        .out_level(ch0_rx_rst)
    );

    sync_ff #(.RESET_VAL(1'b1)) u_ch1_rx_rst_sync (
        .clk(ch1_rx_pclk_int),
        .rst(ch1_rx_pcs_rst_int),
        .in_level(1'b0),
        .out_level(ch1_rx_rst)
    );

    // EXTREFB: Dedicated SERDES reference clock for DCU1
    wire refclk;

    (* LOC="EXTREF1" *)
    EXTREFB #(
        .REFCK_PWDNB ("0b1"),
        .REFCK_RTERM ("0b1"),
        .REFCK_DCBIAS_EN ("0b0")
    ) extref_inst (
        .REFCLKO   (refclk)
    );

    // DCU1 instantiation — GBE mode, 1.25 Gbaud, non-geared
    (* LOC="DCU1" *)
    DCUA #(
        .D_MACROPDB ("0b1"),
        .D_IB_PWDNB ("0b1"),
        .D_TXPLL_PWDNB ("0b1"),
        .D_REFCK_MODE ("0b011"), // x8 multiplier
        .D_TX_MAX_RATE ("1.25"),
        .D_TX_VCO_CK_DIV ("0b010"),
        .D_BITCLK_LOCAL_EN ("0b1"),
        .D_BITCLK_ND_EN ("0b0"),
        .D_BITCLK_FROM_ND_EN ("0b0"),
        .D_SYNC_LOCAL_EN ("0b1"),
        .D_SYNC_ND_EN ("0b0"),
        .D_XGE_MODE ("0b0"),
        .D_BUS8BIT_SEL ("0b0"),
        .D_LOW_MARK ("0d4"),
        .D_HIGH_MARK ("0d12"),
        .D_CDR_LOL_SET ("0b00"),
        .D_PLL_LOL_SET ("0b00"),
        .D_SETPLLRC ("0d1"),
        .D_RG_EN ("0b0"),
        .D_RG_SET ("0b00"),
        .D_CMUSETBIASI ("0b00"),
        .D_CMUSETI4CPP ("0d3"),
        .D_CMUSETI4CPZ ("0d3"),
        .D_CMUSETI4VCO ("0b00"),
        .D_CMUSETICP4P ("0b01"),
        .D_CMUSETICP4Z ("0b101"),
        .D_CMUSETINITVCT ("0b00"),
        .D_CMUSETISCL4VCO ("0b000"),
        .D_CMUSETP1GM ("0b000"),
        .D_CMUSETP2AGM ("0b000"),
        .D_CMUSETZGM ("0b000"),
        .D_SETIRPOLY_AUX ("0b01"),
        .D_SETICONST_AUX ("0b01"),
        .D_SETIRPOLY_CH ("0b01"),
        .D_SETICONST_CH ("0b10"),
        .D_ISETLOS ("0d0"),
        .D_REQ_ISET ("0b011"),
        .D_PD_ISET ("0b11"),
        .D_DCO_CALIB_TIME_SEL ("0b00"),
        .CH0_PROTOCOL ("GBE"),
        .CH0_UC_MODE ("0b0"), // not user-controlled (GBE mode)
        .CH0_ENC_BYPASS ("0b0"),
        .CH0_DEC_BYPASS ("0b0"),
        .CH0_SB_BYPASS ("0b0"), // sync buffer ENABLED
        .CH0_RX_SB_BYPASS ("0b0"), // RX sync buffer ENABLED
        .CH0_WA_BYPASS ("0b0"), // ENABLED — CG_ALIGN needs WA
        .CH0_CTC_BYPASS ("0b0"), // CTC enabled
        .CH0_RX_GEAR_BYPASS ("0b0"),
        .CH0_TX_GEAR_BYPASS ("0b0"),
        .CH0_LSM_DISABLE ("0b0"), // ENABLED
        .CH0_ENABLE_CG_ALIGN ("0b1"),
        .CH0_UDF_COMMA_MASK ("0x3ff"),
        .CH0_UDF_COMMA_A ("0x283"), // K28.5 RD+
        .CH0_UDF_COMMA_B ("0x17C"), // K28.5 RD-
        .CH0_MATCH_2_ENABLE ("0b1"), // 2-char skip matching
        .CH0_MATCH_4_ENABLE ("0b0"),
        .CH0_MIN_IPG_CNT ("0b11"),
        .CH0_CC_MATCH_1 ("0x000"),
        .CH0_CC_MATCH_2 ("0x000"),
        .CH0_CC_MATCH_3 ("0x1BC"), // K28.5 {0,K=1,0xBC}
        .CH0_CC_MATCH_4 ("0x050"), // D16.2 {0,K=0,0x50}
        .CH0_TX_GEAR_MODE ("0b0"),
        .CH0_RX_GEAR_MODE ("0b0"),
        .CH0_FF_TX_H_CLK_EN ("0b0"), // no half-rate TX clock
        .CH0_FF_TX_F_CLK_DIS ("0b0"), // enable full-rate TX clock (125 MHz)
        .CH0_FF_RX_H_CLK_EN ("0b0"), // no half-rate RX clock
        .CH0_FF_RX_F_CLK_DIS ("0b0"), // enable full-rate RX clock (125 MHz)
        .CH0_CDR_MAX_RATE ("1.25"),
        .CH0_RATE_MODE_TX ("0b0"),
        .CH0_RATE_MODE_RX ("0b0"),
        .CH0_TX_DIV11_SEL ("0b0"),
        .CH0_RX_DIV11_SEL ("0b0"),
        .CH0_RX_DCO_CK_DIV ("0b010"),
        .CH0_SEL_SD_RX_CLK ("0b0"), // EBRD clock
        .CH0_AUTO_FACQ_EN ("0b1"),
        .CH0_AUTO_CALIB_EN ("0b1"),
        .CH0_CALIB_CK_MODE ("0b0"),
        .CH0_PDEN_SEL ("0b1"),
        .CH0_PCS_DET_TIME_SEL ("0b00"),
        .CH0_RX_RATE_SEL ("0d10"),
        .CH0_DCOATDCFG ("0b00"),
        .CH0_DCOATDDLY ("0b00"),
        .CH0_DCOBYPSATD ("0b1"),
        .CH0_DCOCALDIV ("0b000"),
        .CH0_DCOCTLGI ("0b011"),
        .CH0_DCODISBDAVOID ("0b0"),
        .CH0_DCOFLTDAC ("0b00"),
        .CH0_DCOFTNRG ("0b001"),
        .CH0_DCOIOSTUNE ("0b010"),
        .CH0_DCOITUNE ("0b00"),
        .CH0_DCOITUNE4LSB ("0b010"),
        .CH0_DCOIUPDNX2 ("0b1"),
        .CH0_DCONUOFLSB ("0b100"),
        .CH0_DCOSCALEI ("0b01"),
        .CH0_DCOSTARTVAL ("0b010"),
        .CH0_DCOSTEP ("0b11"),
        .CH0_BAND_THRESHOLD ("0d0"),
        .CH0_CDR_CNT4SEL ("0b00"),
        .CH0_CDR_CNT8SEL ("0b00"),
        .CH0_REG_BAND_OFFSET ("0d0"),
        .CH0_REG_BAND_SEL ("0d0"),
        .CH0_REG_IDAC_SEL ("0d0"),
        .CH0_REG_IDAC_EN ("0b0"),
        .CH0_RPWDNB ("0b1"),
        .CH0_RTERM_RX ("0d31"), // 62 ohm board-proven setting
        .CH0_RXIN_CM ("0b11"),
        .CH0_RXTERM_CM ("0b11"),
        .CH0_RCV_DCC_EN ("0b0"),
        .CH0_RLOS_SEL ("0b1"),
        .CH0_RX_LOS_EN ("0b1"),
        .CH0_RX_LOS_LVL ("0b100"),
        .CH0_RX_LOS_CEQ ("0b11"),
        .CH0_RX_LOS_HYST_EN ("0b0"),
        .CH0_REQ_EN ("0b0"),
        .CH0_REQ_LVL_SET ("0b00"),
        .CH0_LEQ_OFFSET_SEL ("0b0"),
        .CH0_LEQ_OFFSET_TRIM ("0b000"),
        .CH0_LDR_RX2CORE_SEL ("0b0"),
        .CH0_TPWDNB ("0b1"),
        .CH0_RTERM_TX ("0d19"),
        .CH0_TXAMPLITUDE ("0d400"),
        .CH0_TXDEPRE ("DISABLED"),
        .CH0_TXDEPOST ("DISABLED"),
        .CH0_TX_CM_SEL ("0b00"),
        .CH0_TDRV_PRE_EN ("0b0"),
        .CH0_TDRV_DAT_SEL ("0b00"),
        .CH0_TX_POST_SIGN ("0b0"),
        .CH0_TX_PRE_SIGN ("0b0"),
        .CH0_LDR_CORE2TX_SEL ("0b0"),
        .CH0_TDRV_SLICE0_SEL ("0b01"),
        .CH0_TDRV_SLICE0_CUR ("0b011"),
        .CH0_TDRV_SLICE1_SEL ("0b00"),
        .CH0_TDRV_SLICE1_CUR ("0b000"),
        .CH0_TDRV_SLICE2_SEL ("0b01"),
        .CH0_TDRV_SLICE2_CUR ("0b11"),
        .CH0_TDRV_SLICE3_SEL ("0b01"),
        .CH0_TDRV_SLICE3_CUR ("0b10"),
        .CH0_TDRV_SLICE4_SEL ("0b00"),
        .CH0_TDRV_SLICE4_CUR ("0b00"),
        .CH0_TDRV_SLICE5_SEL ("0b00"),
        .CH0_TDRV_SLICE5_CUR ("0b00"),
        .CH1_PROTOCOL ("GBE"),
        .CH1_UC_MODE ("0b0"),
        .CH1_ENC_BYPASS ("0b0"),
        .CH1_DEC_BYPASS ("0b0"),
        .CH1_SB_BYPASS ("0b0"),
        .CH1_RX_SB_BYPASS ("0b0"),
        .CH1_WA_BYPASS ("0b0"),
        .CH1_CTC_BYPASS ("0b0"), // CTC enabled
        .CH1_RX_GEAR_BYPASS ("0b0"),
        .CH1_TX_GEAR_BYPASS ("0b0"),
        .CH1_LSM_DISABLE ("0b0"),
        .CH1_ENABLE_CG_ALIGN ("0b1"),
        .CH1_UDF_COMMA_MASK ("0x3ff"),
        .CH1_UDF_COMMA_A ("0x283"),
        .CH1_UDF_COMMA_B ("0x17C"),
        .CH1_MATCH_2_ENABLE ("0b1"), // 2-char skip matching
        .CH1_MATCH_4_ENABLE ("0b0"),
        .CH1_MIN_IPG_CNT ("0b11"),
        .CH1_CC_MATCH_1 ("0x000"),
        .CH1_CC_MATCH_2 ("0x000"),
        .CH1_CC_MATCH_3 ("0x1BC"), // K28.5 {0,K=1,0xBC}
        .CH1_CC_MATCH_4 ("0x050"), // D16.2 {0,K=0,0x50}
        .CH1_TX_GEAR_MODE ("0b0"),
        .CH1_RX_GEAR_MODE ("0b0"),
        .CH1_FF_TX_H_CLK_EN ("0b0"),
        .CH1_FF_TX_F_CLK_DIS ("0b0"),
        .CH1_FF_RX_H_CLK_EN ("0b0"),
        .CH1_FF_RX_F_CLK_DIS ("0b0"),
        .CH1_CDR_MAX_RATE ("1.25"),
        .CH1_RATE_MODE_TX ("0b0"),
        .CH1_RATE_MODE_RX ("0b0"),
        .CH1_TX_DIV11_SEL ("0b0"),
        .CH1_RX_DIV11_SEL ("0b0"),
        .CH1_RX_DCO_CK_DIV ("0b010"),
        .CH1_SEL_SD_RX_CLK ("0b0"), // EBRD clock
        .CH1_AUTO_FACQ_EN ("0b1"),
        .CH1_AUTO_CALIB_EN ("0b1"),
        .CH1_CALIB_CK_MODE ("0b0"),
        .CH1_PDEN_SEL ("0b1"),
        .CH1_PCS_DET_TIME_SEL ("0b00"),
        .CH1_RX_RATE_SEL ("0d10"),
        .CH1_DCOATDCFG ("0b00"),
        .CH1_DCOATDDLY ("0b00"),
        .CH1_DCOBYPSATD ("0b1"),
        .CH1_DCOCALDIV ("0b000"),
        .CH1_DCOCTLGI ("0b011"),
        .CH1_DCODISBDAVOID ("0b0"),
        .CH1_DCOFLTDAC ("0b00"),
        .CH1_DCOFTNRG ("0b001"),
        .CH1_DCOIOSTUNE ("0b010"),
        .CH1_DCOITUNE ("0b00"),
        .CH1_DCOITUNE4LSB ("0b010"),
        .CH1_DCOIUPDNX2 ("0b1"),
        .CH1_DCONUOFLSB ("0b100"),
        .CH1_DCOSCALEI ("0b01"),
        .CH1_DCOSTARTVAL ("0b010"),
        .CH1_DCOSTEP ("0b11"),
        .CH1_BAND_THRESHOLD ("0d0"),
        .CH1_CDR_CNT4SEL ("0b00"),
        .CH1_CDR_CNT8SEL ("0b00"),
        .CH1_REG_BAND_OFFSET ("0d0"),
        .CH1_REG_BAND_SEL ("0d0"),
        .CH1_REG_IDAC_SEL ("0d0"),
        .CH1_REG_IDAC_EN ("0b0"),
        .CH1_RPWDNB ("0b1"),
        .CH1_RTERM_RX ("0d31"), // 62 ohm board-proven setting
        .CH1_RXIN_CM ("0b11"),
        .CH1_RXTERM_CM ("0b11"),
        .CH1_RCV_DCC_EN ("0b0"),
        .CH1_RLOS_SEL ("0b1"),
        .CH1_RX_LOS_EN ("0b1"),
        .CH1_RX_LOS_LVL ("0b100"),
        .CH1_RX_LOS_CEQ ("0b11"),
        .CH1_RX_LOS_HYST_EN ("0b0"),
        .CH1_REQ_EN ("0b0"),
        .CH1_REQ_LVL_SET ("0b00"),
        .CH1_LEQ_OFFSET_SEL ("0b0"),
        .CH1_LEQ_OFFSET_TRIM ("0b000"),
        .CH1_LDR_RX2CORE_SEL ("0b0"),
        .CH1_TPWDNB ("0b1"),
        .CH1_RTERM_TX ("0d19"),
        .CH1_TXAMPLITUDE ("0d400"),
        .CH1_TXDEPRE ("DISABLED"),
        .CH1_TXDEPOST ("DISABLED"),
        .CH1_TX_CM_SEL ("0b00"),
        .CH1_TDRV_PRE_EN ("0b0"),
        .CH1_TDRV_DAT_SEL ("0b00"),
        .CH1_TX_POST_SIGN ("0b0"),
        .CH1_TX_PRE_SIGN ("0b0"),
        .CH1_LDR_CORE2TX_SEL ("0b0"),
        .CH1_TDRV_SLICE0_SEL ("0b01"),
        .CH1_TDRV_SLICE0_CUR ("0b011"),
        .CH1_TDRV_SLICE1_SEL ("0b00"),
        .CH1_TDRV_SLICE1_CUR ("0b000"),
        .CH1_TDRV_SLICE2_SEL ("0b01"),
        .CH1_TDRV_SLICE2_CUR ("0b11"),
        .CH1_TDRV_SLICE3_SEL ("0b01"),
        .CH1_TDRV_SLICE3_CUR ("0b10"),
        .CH1_TDRV_SLICE4_SEL ("0b00"),
        .CH1_TDRV_SLICE4_CUR ("0b00"),
        .CH1_TDRV_SLICE5_SEL ("0b00"),
        .CH1_TDRV_SLICE5_CUR ("0b00")
    ) DCU1_inst (
        // DCU-level signals
        .D_REFCLKI          (refclk),
        .D_FFC_MACRO_RST    (dcu_rst),
        .D_FFC_DUAL_RST     (dcu_rst),
        .D_FFC_TRST         (tx_serdes_rst),
        .D_FFC_MACROPDB     (1'b1),
        .D_FFS_PLOL         (tx_pll_lol),

        // Channel 0 (PHY1)
        .CH0_RX_REFCLK      (refclk),
        .CH0_FF_RXI_CLK     (ch0_rx_pclk_int),
        .CH0_FF_RX_PCLK     (ch0_rx_pclk_int),
        .CH0_FF_EBRD_CLK    (ch0_rx_pclk_int),
        .CH0_FF_TXI_CLK     (ch0_tx_pclk_int),  // TX_PCLK -> TXI_CLK loopback (internal)
        .CH0_FF_TX_PCLK     (ch0_tx_pclk_int),

        .CH0_FFC_RXPWDNB    (1'b1),
        .CH0_FFC_TXPWDNB    (1'b1),
        .CH0_FFC_RRST       (ch0_rx_serdes_rst_int),
        .CH0_FFC_LANE_RX_RST(ch0_rx_pcs_rst_int),
        .CH0_FFC_LANE_TX_RST(tx_pcs_rst),
        .CH0_FFC_SIGNAL_DETECT(1'b1),  // hardwired
        .CH0_FFC_FB_LOOPBACK(1'b0),

        .CH0_FFS_RLOS       (ch0_rx_los),
        .CH0_FFS_RLOL       (ch0_rx_cdr_lol),
        .CH0_FFS_LS_SYNC_STATUS(ch0_lsm_status),

        // CH0 TX data bus (24-bit)
        .CH0_FF_TX_D_0      (ch0_tx_d[0]),
        .CH0_FF_TX_D_1      (ch0_tx_d[1]),
        .CH0_FF_TX_D_2      (ch0_tx_d[2]),
        .CH0_FF_TX_D_3      (ch0_tx_d[3]),
        .CH0_FF_TX_D_4      (ch0_tx_d[4]),
        .CH0_FF_TX_D_5      (ch0_tx_d[5]),
        .CH0_FF_TX_D_6      (ch0_tx_d[6]),
        .CH0_FF_TX_D_7      (ch0_tx_d[7]),
        .CH0_FF_TX_D_8      (ch0_tx_d[8]),
        .CH0_FF_TX_D_9      (ch0_tx_d[9]),
        .CH0_FF_TX_D_10     (ch0_tx_d[10]),
        .CH0_FF_TX_D_11     (ch0_tx_d[11]),
        .CH0_FF_TX_D_12     (ch0_tx_d[12]),
        .CH0_FF_TX_D_13     (ch0_tx_d[13]),
        .CH0_FF_TX_D_14     (ch0_tx_d[14]),
        .CH0_FF_TX_D_15     (ch0_tx_d[15]),
        .CH0_FF_TX_D_16     (ch0_tx_d[16]),
        .CH0_FF_TX_D_17     (ch0_tx_d[17]),
        .CH0_FF_TX_D_18     (ch0_tx_d[18]),
        .CH0_FF_TX_D_19     (ch0_tx_d[19]),
        .CH0_FF_TX_D_20     (ch0_tx_d[20]),
        .CH0_FF_TX_D_21     (ch0_tx_d[21]),
        .CH0_FF_TX_D_22     (ch0_tx_d[22]),
        .CH0_FF_TX_D_23     (ch0_tx_d[23]),

        // CH0 RX data bus (24-bit)
        .CH0_FF_RX_D_0      (ch0_rx_d[0]),
        .CH0_FF_RX_D_1      (ch0_rx_d[1]),
        .CH0_FF_RX_D_2      (ch0_rx_d[2]),
        .CH0_FF_RX_D_3      (ch0_rx_d[3]),
        .CH0_FF_RX_D_4      (ch0_rx_d[4]),
        .CH0_FF_RX_D_5      (ch0_rx_d[5]),
        .CH0_FF_RX_D_6      (ch0_rx_d[6]),
        .CH0_FF_RX_D_7      (ch0_rx_d[7]),
        .CH0_FF_RX_D_8      (ch0_rx_d[8]),
        .CH0_FF_RX_D_9      (ch0_rx_d[9]),
        .CH0_FF_RX_D_10     (ch0_rx_d[10]),
        .CH0_FF_RX_D_11     (ch0_rx_d[11]),
        .CH0_FF_RX_D_12     (ch0_rx_d[12]),
        .CH0_FF_RX_D_13     (ch0_rx_d[13]),
        .CH0_FF_RX_D_14     (ch0_rx_d[14]),
        .CH0_FF_RX_D_15     (ch0_rx_d[15]),
        .CH0_FF_RX_D_16     (ch0_rx_d[16]),
        .CH0_FF_RX_D_17     (ch0_rx_d[17]),
        .CH0_FF_RX_D_18     (ch0_rx_d[18]),
        .CH0_FF_RX_D_19     (ch0_rx_d[19]),
        .CH0_FF_RX_D_20     (ch0_rx_d[20]),
        .CH0_FF_RX_D_21     (ch0_rx_d[21]),
        .CH0_FF_RX_D_22     (ch0_rx_d[22]),
        .CH0_FF_RX_D_23     (ch0_rx_d[23]),

        // Channel 1 (PHY2)
        .CH1_RX_REFCLK      (refclk),
        .CH1_FF_RXI_CLK     (ch1_rx_pclk_int),
        .CH1_FF_RX_PCLK     (ch1_rx_pclk_int),
        .CH1_FF_EBRD_CLK    (ch1_rx_pclk_int),
        .CH1_FF_TXI_CLK     (ch1_tx_pclk_int),  // TX_PCLK -> TXI_CLK loopback (internal)
        .CH1_FF_TX_PCLK     (ch1_tx_pclk_int),

        .CH1_FFC_RXPWDNB    (1'b1),
        .CH1_FFC_TXPWDNB    (1'b1),
        .CH1_FFC_RRST       (ch1_rx_serdes_rst_int),
        .CH1_FFC_LANE_RX_RST(ch1_rx_pcs_rst_int),
        .CH1_FFC_LANE_TX_RST(tx_pcs_rst),
        .CH1_FFC_SIGNAL_DETECT(1'b1),  // hardwired
        .CH1_FFC_FB_LOOPBACK(1'b0),

        .CH1_FFS_RLOS       (ch1_rx_los),
        .CH1_FFS_RLOL       (ch1_rx_cdr_lol),
        .CH1_FFS_LS_SYNC_STATUS(ch1_lsm_status),

        // CH1 TX data bus
        .CH1_FF_TX_D_0      (ch1_tx_d[0]),
        .CH1_FF_TX_D_1      (ch1_tx_d[1]),
        .CH1_FF_TX_D_2      (ch1_tx_d[2]),
        .CH1_FF_TX_D_3      (ch1_tx_d[3]),
        .CH1_FF_TX_D_4      (ch1_tx_d[4]),
        .CH1_FF_TX_D_5      (ch1_tx_d[5]),
        .CH1_FF_TX_D_6      (ch1_tx_d[6]),
        .CH1_FF_TX_D_7      (ch1_tx_d[7]),
        .CH1_FF_TX_D_8      (ch1_tx_d[8]),
        .CH1_FF_TX_D_9      (ch1_tx_d[9]),
        .CH1_FF_TX_D_10     (ch1_tx_d[10]),
        .CH1_FF_TX_D_11     (ch1_tx_d[11]),
        .CH1_FF_TX_D_12     (ch1_tx_d[12]),
        .CH1_FF_TX_D_13     (ch1_tx_d[13]),
        .CH1_FF_TX_D_14     (ch1_tx_d[14]),
        .CH1_FF_TX_D_15     (ch1_tx_d[15]),
        .CH1_FF_TX_D_16     (ch1_tx_d[16]),
        .CH1_FF_TX_D_17     (ch1_tx_d[17]),
        .CH1_FF_TX_D_18     (ch1_tx_d[18]),
        .CH1_FF_TX_D_19     (ch1_tx_d[19]),
        .CH1_FF_TX_D_20     (ch1_tx_d[20]),
        .CH1_FF_TX_D_21     (ch1_tx_d[21]),
        .CH1_FF_TX_D_22     (ch1_tx_d[22]),
        .CH1_FF_TX_D_23     (ch1_tx_d[23]),

        // CH1 RX data bus
        .CH1_FF_RX_D_0      (ch1_rx_d[0]),
        .CH1_FF_RX_D_1      (ch1_rx_d[1]),
        .CH1_FF_RX_D_2      (ch1_rx_d[2]),
        .CH1_FF_RX_D_3      (ch1_rx_d[3]),
        .CH1_FF_RX_D_4      (ch1_rx_d[4]),
        .CH1_FF_RX_D_5      (ch1_rx_d[5]),
        .CH1_FF_RX_D_6      (ch1_rx_d[6]),
        .CH1_FF_RX_D_7      (ch1_rx_d[7]),
        .CH1_FF_RX_D_8      (ch1_rx_d[8]),
        .CH1_FF_RX_D_9      (ch1_rx_d[9]),
        .CH1_FF_RX_D_10     (ch1_rx_d[10]),
        .CH1_FF_RX_D_11     (ch1_rx_d[11]),
        .CH1_FF_RX_D_12     (ch1_rx_d[12]),
        .CH1_FF_RX_D_13     (ch1_rx_d[13]),
        .CH1_FF_RX_D_14     (ch1_rx_d[14]),
        .CH1_FF_RX_D_15     (ch1_rx_d[15]),
        .CH1_FF_RX_D_16     (ch1_rx_d[16]),
        .CH1_FF_RX_D_17     (ch1_rx_d[17]),
        .CH1_FF_RX_D_18     (ch1_rx_d[18]),
        .CH1_FF_RX_D_19     (ch1_rx_d[19]),
        .CH1_FF_RX_D_20     (ch1_rx_d[20]),
        .CH1_FF_RX_D_21     (ch1_rx_d[21]),
        .CH1_FF_RX_D_22     (ch1_rx_d[22]),
        .CH1_FF_RX_D_23     (ch1_rx_d[23])
    );

endmodule
