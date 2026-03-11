PREFIX   ?= riscv64-elf-
CC       := $(PREFIX)gcc
OBJCOPY  := $(PREFIX)objcopy
OBJDUMP  := $(PREFIX)objdump
SIZE     := $(PREFIX)size
NM       := $(PREFIX)nm
RUSTC    ?= rustup run stable rustc
RUST_TARGET ?= riscv32i-unknown-none-elf

ARCH     := -march=rv32i -mabi=ilp32
LDFLAGS  := $(ARCH) -T link.ld -nostdlib -Wl,--gc-sections
RUSTFLAGS := --target $(RUST_TARGET) --edition=2021 -C opt-level=s -C panic=abort -C codegen-units=1 -C relocation-model=static
MULDIV_HELPER_RE := __([u]?div|[u]?mod|mul|[u]?divmod)[A-Za-z0-9_]+

BUILD_DIR ?= ../build/firmware
RUST_LIB := $(BUILD_DIR)/libfirmware.a
TARGET   := $(BUILD_DIR)/firmware
RUST_PROBE_RS := $(BUILD_DIR)/rust_target_probe.rs
RUST_PROBE_O  := $(BUILD_DIR)/rust_target_probe.o
MULDIV_NM     := $(BUILD_DIR)/.muldiv_check.nm
MULDIV_DIS    := $(BUILD_DIR)/.muldiv_check.dis
ROM_SECTIONS  := --only-section .text.start --only-section .trap --only-section .text --only-section .rodata
.PHONY: all clean check-tools

all: check-tools $(TARGET).hex

check-tools:
	@set -e; \
		for tool in "$(CC)" "$(OBJCOPY)" "$(OBJDUMP)" "$(SIZE)" "$(NM)"; do \
		if ! command -v "$$tool" >/dev/null 2>&1; then \
			echo "ERROR: missing required tool '$$tool'"; \
			exit 1; \
		fi; \
	done
	@set -e; \
	if ! $(RUSTC) --version >/dev/null 2>&1; then \
		echo "ERROR: RUSTC command failed: $(RUSTC)"; \
		exit 1; \
	fi; \
	mkdir -p $(BUILD_DIR); \
	printf '%s\n' '#![no_std]' 'pub fn _probe() {}' > $(RUST_PROBE_RS); \
	if ! $(RUSTC) --target $(RUST_TARGET) --edition=2021 -C panic=abort --crate-type lib --emit=obj -o $(RUST_PROBE_O) $(RUST_PROBE_RS) >/dev/null 2>&1; then \
		rm -f $(RUST_PROBE_RS) $(RUST_PROBE_O); \
		echo "ERROR: Rust target $(RUST_TARGET) is unavailable for RUSTC='$(RUSTC)'"; \
		echo "Hint: install target via rustup or set RUSTC to a toolchain that has $(RUST_TARGET)."; \
		exit 1; \
	fi; \
	rm -f $(RUST_PROBE_RS) $(RUST_PROBE_O)

$(BUILD_DIR):
	mkdir -p $@

$(RUST_LIB): main.rs cli.rs line_edit.rs mdio.rs parse.rs soc_map.rs uart_util.rs | $(BUILD_DIR)
	$(RUSTC) $(RUSTFLAGS) --crate-type staticlib -o $@ main.rs

$(TARGET).elf: check-tools $(RUST_LIB) link.ld | $(BUILD_DIR)
	$(CC) $(LDFLAGS) -o $@ $(RUST_LIB)
	@set -e; \
			$(NM) -a $@ > $(MULDIV_NM); \
			if grep -Eq "$(MULDIV_HELPER_RE)" $(MULDIV_NM); then \
				echo "ERROR: Non-hardware mul/div/mod helper symbol detected in firmware.elf"; \
			echo "Use shift/add/sub implementations only (rv32i, no M extension)."; \
			rm -f $(MULDIV_NM); \
			exit 1; \
		fi; \
		rm -f $(MULDIV_NM)
	$(SIZE) $@

$(TARGET).hex: $(TARGET).elf | $(BUILD_DIR)
	$(OBJCOPY) -S -O verilog --verilog-data-width 4 --gap-fill 0 $(ROM_SECTIONS) $< $@
	$(OBJDUMP) -d $< > $(TARGET).dis

clean:
	rm -rf $(BUILD_DIR)
