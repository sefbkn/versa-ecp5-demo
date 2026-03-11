// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Youssef Boukenken

use core::ptr::{read_volatile, write_volatile};

// Mirrors the MMIO map in rtl/soc/control_soc.v.
pub const UART_BASE: usize = 0x2000_0000;
pub const MDIO_BASE: usize = 0x3000_0000;

#[derive(Clone, Copy)]
pub struct ReadOnlyRegister {
    addr: *const u32,
}

impl ReadOnlyRegister {
    pub const fn new(addr: usize) -> Self {
        Self {
            addr: addr as *const u32,
        }
    }

    #[inline(always)]
    pub fn read(self) -> u32 {
        unsafe { read_volatile(self.addr) }
    }
}

#[derive(Clone, Copy)]
pub struct WriteOnlyRegister {
    addr: *mut u32,
}

impl WriteOnlyRegister {
    pub const fn new(addr: usize) -> Self {
        Self {
            addr: addr as *mut u32,
        }
    }

    #[inline(always)]
    pub fn write(self, value: u32) {
        unsafe { write_volatile(self.addr, value) }
    }
}

#[derive(Clone, Copy)]
pub struct ReadWriteRegister {
    addr: *mut u32,
}

impl ReadWriteRegister {
    pub const fn new(addr: usize) -> Self {
        Self {
            addr: addr as *mut u32,
        }
    }

    #[inline(always)]
    pub fn read(self) -> u32 {
        unsafe { read_volatile(self.addr as *const u32) }
    }

    #[inline(always)]
    pub fn write(self, value: u32) {
        unsafe { write_volatile(self.addr, value) }
    }
}

pub const UART_TX_READY: ReadOnlyRegister = ReadOnlyRegister::new(UART_BASE);
pub const UART_TX_DATA: WriteOnlyRegister = WriteOnlyRegister::new(UART_BASE + 0x04);
pub const UART_RX_DATA: ReadOnlyRegister = ReadOnlyRegister::new(UART_BASE + 0x08);
pub const UART_RX_VALID: ReadOnlyRegister = ReadOnlyRegister::new(UART_BASE + 0x0C);

pub const MDIO_CTRL: ReadWriteRegister = ReadWriteRegister::new(MDIO_BASE);
pub const MDIO_RDATA: ReadOnlyRegister = ReadOnlyRegister::new(MDIO_BASE + 0x08);

pub const MDIO_CTRL_GO: u32 = 0x0000_0001;
pub const MDIO_CTRL_PAGE_SHIFT: u32 = 13;
pub const MDIO_CTRL_REG_ADDR_SHIFT: u32 = 8;
pub const MDIO_CTRL_ERROR: u32 = 0x2000_0000;
pub const MDIO_CTRL_DONE: u32 = 0x4000_0000;
pub const MDIO_CTRL_BUSY: u32 = 0x8000_0000;
