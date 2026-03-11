DESIGN    = versa_demo
TOP       = versa_demo_top
PACKAGE   = CABGA381
SPEED     = 8
SEED     ?= 1
ETH_MODE_SGMII ?= 1

FW_DIR     = firmware
BUILD_DIR  = build
SIM_BUILD_DIR = $(BUILD_DIR)/sim
IVERILOG  ?= iverilog
VVP       ?= vvp

ifeq ($(ETH_MODE_SGMII),1)
LPF = constraints/versa_sgmii.lpf
else
LPF = constraints/versa_rgmii.lpf
endif

VERILOG = \
	rtl/common/async_frame_fifo.v \
	rtl/ethernet/eth_fcs_filter.v \
	rtl/common/sync_ff.v \
	rtl/led_blinkshow.v \
	rtl/ethernet/eth_dataplane.v \
	rtl/ethernet/ethernet_top.v \
	rtl/ethernet/control/eth_ctrl_plane.v \
	rtl/ethernet/control/eth_mgmt.v \
	rtl/ethernet/mdio/mdio_master.v \
	rtl/ethernet/mdio/mdio_paged.v \
	rtl/ethernet/mdio/mdio_req_exec.v \
	rtl/ethernet/phy/phy_init.v \
	rtl/ethernet/rgmii/rgmii_port.v \
	rtl/ethernet/rgmii/rgmii_rx.v \
	rtl/ethernet/rgmii/rgmii_tx.v \
	rtl/ethernet/sgmii/sgmii_dcu.v \
	rtl/ethernet/sgmii/serdes_rx_recover.v \
	rtl/ethernet/sgmii/sgmii_an.v \
	rtl/ethernet/sgmii/sgmii_pcs.v \
	rtl/ethernet/sgmii/sgmii_rx.v \
	rtl/ethernet/sgmii/sgmii_tx.v \
	rtl/external/vexriscv/VexRiscv.v \
	rtl/soc/control_soc.v \
	rtl/soc/data_ram.v \
	rtl/soc/instr_rom.v \
	rtl/soc/mdio_mmio.v \
	rtl/soc/uart_mmio.v \
	rtl/uart/uart_rx.v \
	rtl/uart/uart_tx.v \
	rtl/top.v

SEED_STAMP  = $(BUILD_DIR)/.seed_$(SEED)
JSON        = $(BUILD_DIR)/$(DESIGN).json
CONFIG      = $(BUILD_DIR)/$(DESIGN)_out.config
BITSTREAM   = $(BUILD_DIR)/$(DESIGN).bit
TIMING      = $(BUILD_DIR)/$(DESIGN)_timing.json
PNR_LOG     = $(BUILD_DIR)/$(DESIGN)_pnr.log

.PHONY: help all synth pnr pack prog clean firmware sim_async_frame_fifo

help:
	@echo "Targets:"
	@echo "  make all                      # Build bitstream"
	@echo "  make prog                     # Program board via openFPGALoader"
	@echo "  make sim_async_frame_fifo     # Run async FIFO simulation"
	@echo "  make clean                    # Remove build artifacts"

all: $(BITSTREAM)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

firmware:
	$(MAKE) -C $(FW_DIR) all

$(SEED_STAMP): | $(BUILD_DIR)
	rm -f $(BUILD_DIR)/.seed_*
	echo "$(SEED)" > $@

sim_async_frame_fifo: $(SIM_BUILD_DIR)/tb_async_frame_fifo.vvp
	$(VVP) $<

$(SIM_BUILD_DIR):
	mkdir -p $@

$(SIM_BUILD_DIR)/tb_async_frame_fifo.vvp: rtl/common/async_frame_fifo.v rtl/common/sync_ff.v sim/tb_async_frame_fifo.v | $(SIM_BUILD_DIR)
	$(IVERILOG) -g2012 -Wall -Wno-timescale -s tb_async_frame_fifo -o $@ $^

synth: $(JSON)
$(JSON): firmware $(VERILOG) | $(BUILD_DIR)
		yosys -p "read_verilog $(VERILOG); chparam -set PORT_MODE_SGMII $(ETH_MODE_SGMII) $(TOP); synth_ecp5 -top $(TOP) -json $@"

pnr: $(CONFIG)
$(CONFIG): $(JSON) $(LPF) $(SEED_STAMP)
	nextpnr-ecp5 --um5g-45k --package $(PACKAGE) --speed $(SPEED) \
		--seed $(SEED) --lpf $(LPF) --json $(JSON) --textcfg $@ \
		--placer-heap-timingweight 20 --placer-heap-critexp 1 \
		--report $(TIMING) 2>&1 | tee $(PNR_LOG) && \
	if grep -q 'FAIL' $(PNR_LOG); then echo "ERROR: timing failure"; exit 1; fi

pack: $(BITSTREAM)
$(BITSTREAM): $(CONFIG)
	ecppack --compress --idcode 0x81112043 --input $< --bit $@

prog: $(BITSTREAM)
	openFPGALoader --board versa_ecp5 $<

clean:
	rm -rf $(BUILD_DIR)
	$(MAKE) -C $(FW_DIR) clean
