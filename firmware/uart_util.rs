// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Youssef Boukenken

use core::fmt::{self, Write};

use crate::soc_map::{UART_RX_DATA, UART_RX_VALID, UART_TX_DATA, UART_TX_READY};

pub struct UartWriter;

pub fn uart_try_putc(c: u8) -> bool {
    if UART_TX_READY.read() == 0 {
        return false;
    }

    UART_TX_DATA.write(c as u32);
    true
}

pub fn uart_putc(c: u8) {
    while !uart_try_putc(c) {}
}

pub fn uart_puts(s: &str) {
    for &b in s.as_bytes() {
        uart_putc(b);
    }
}

pub fn uart_try_puts(s: &str) {
    for &b in s.as_bytes() {
        if !uart_try_putc(b) {
            break;
        }
    }
}

impl Write for UartWriter {
    fn write_str(&mut self, s: &str) -> fmt::Result {
        uart_puts(s);
        Ok(())
    }
}

pub fn uart_getc_nb() -> Option<u8> {
    if UART_RX_VALID.read() == 0 {
        None
    } else {
        Some((UART_RX_DATA.read() & 0xFF) as u8)
    }
}
