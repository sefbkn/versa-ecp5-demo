# Versa ECP5 Demo

This repository produces a bitstream for the `Lattice Versa ECP5-5G` board that
bridges the two onboard Ethernet PHYs. The datapath is intentionally simple:
frames received on port 1 are buffered and sent out port 2, and frames received
on port 2 are sent out port 1.

There is also a small RV32I VexRiscv control core. It exists to bring the PHYs
up over MDIO and to expose a UART CLI for register inspection. This is a
bring-up/demo image, not a general-purpose network stack.

## Current Scope

- Dual-port hardware passthrough
- One interface mode per build for both ports
- PHY reset and MDIO init handled in RTL
- UART CLI for MDIO inspection
- Async FIFO simulation target

The design uses the board's 100 MHz clock, FT2232H USB JTAG/UART path, and the
two onboard `88E1512` PHYs. It does not currently use DDR3, PCIe, SPI flash
boot, the 14-segment display, or the expansion connectors.

## Build

You need the FPGA toolchain:

- `yosys`
- `nextpnr-ecp5`
- `ecppack`
- `openFPGALoader`

You also need the firmware toolchain used by `firmware/Makefile`:

- `riscv64-elf-gcc`
- `riscv64-elf-objcopy`
- `riscv64-elf-objdump`
- `riscv64-elf-size`
- `riscv64-elf-nm`
- Rust with target `riscv32i-unknown-none-elf`

`make all` builds the firmware first and then synthesizes the FPGA image.

Default build is SGMII on both ports:

```bash
make all
make prog
```

RGMII build:

```bash
make ETH_MODE_SGMII=0 all
make ETH_MODE_SGMII=0 prog
```

The top-level Makefile switches between `constraints/versa_sgmii.lpf` and
`constraints/versa_rgmii.lpf` and passes the same mode into `rtl/top.v`.

For the small simulation that is already wired up:

```bash
make sim_async_frame_fifo
```

## Bring-Up Notes

The board already exposes JTAG and UART over the onboard FT2232H, so a single
USB cable is enough for programming and the CLI.

In SGMII builds, the design uses the ECP5 DCU path through
`rtl/ethernet/sgmii/sgmii_dcu.v`. In RGMII builds, both PHY ports use the GPIO
RGMII path through `rtl/ethernet/rgmii/rgmii_port.v`.

The two ports always use the same mode in a given build. Mixed SGMII/RGMII
operation is not implemented here.

## UART CLI

The UART firmware is intentionally small. Current commands are:

```text
help
phy dump
phy dump all
```

The UART TX/RX RTL is hard-coded for 4 Mbaud off the 100 MHz system clock.

## Layout

- `rtl/top.v`: board top-level, clock input, UART SoC hookup, LED output
- `rtl/ethernet/ethernet_top.v`: Ethernet subsystem wrapper
- `rtl/ethernet/control/eth_mgmt.v`: reset generation, PHY init, MDIO bridge
- `rtl/ethernet/control/eth_ctrl_plane.v`: control-plane request/response shim
- `rtl/ethernet/eth_dataplane.v`: mode selection plus port-to-port forwarding
- `rtl/ethernet/eth_fcs_filter.v`: drops bad RX frames before they enter the FIFOs
- `rtl/ethernet/mdio/`: MDIO engine and request helpers
- `rtl/ethernet/phy/`: PHY bring-up sequence
- `rtl/ethernet/sgmii/`: SGMII PCS, auto-negotiation, and DCU wrapper
- `rtl/ethernet/rgmii/`: RGMII frontend
- `rtl/soc/`: VexRiscv wrapper and MMIO blocks
- `rtl/common/`: async FIFO and synchronizer primitives
- `firmware/`: Rust firmware for the UART/MDIO CLI

## License

Original RTL, constraints, and simulation files are licensed under
`CERN-OHL-S-2.0`. Original firmware, tools, build scripts, and documentation are
licensed under `MIT`. Vendored code under `rtl/external/` keeps its upstream
licenses.

See [LICENSE](LICENSE) and the full texts under `LICENSES/`.
