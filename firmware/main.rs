// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Youssef Boukenken

#![no_std]
#![no_main]

mod cli;
mod line_edit;
mod mdio;
mod parse;
mod soc_map;
mod uart_util;

use cli::{print_banner, print_prompt, run_cmd};
use core::arch::global_asm;
use core::panic::PanicInfo;
use line_edit::{EditEvent, LineEditor};
use uart_util::{uart_getc_nb, uart_putc, uart_puts, uart_try_puts};

global_asm!(
    r#"
    .section .text.start, "ax"
    .global _start

_start:
    lui     sp, %hi(__stack_top)
    addi    sp, sp, %lo(__stack_top)

    .option push
    .option norelax
    la      gp, __global_pointer$
    .option pop

    j       main

    .section .trap, "ax"
    .global _trap
    .align  4

_trap:
1:  wfi
    j       1b
"#
);

#[panic_handler]
fn panic(_info: &PanicInfo<'_>) -> ! {
    uart_try_puts("\r\nPANIC\r\n");
    loop {}
}

#[no_mangle]
pub extern "C" fn main() -> ! {
    let mut editor = LineEditor::new();

    print_banner();
    print_prompt();

    loop {
        let byte = match uart_getc_nb() {
            Some(byte) => byte,
            None => continue,
        };

        match editor.feed(byte) {
            EditEvent::None => {}
            EditEvent::Echo(byte) => uart_putc(byte),
            EditEvent::Backspace => uart_puts("\x08 \x08"),
            EditEvent::LineReady(line_len) => {
                uart_puts("\r\n");
                run_cmd(editor.line(line_len));
                print_prompt();
            }
            EditEvent::OverflowStarted => {
                uart_puts("\r\nERR: line too long (discarding until newline)\r\n");
            }
            EditEvent::OverflowFinished => {
                uart_puts("\r\n");
                print_prompt();
            }
        }
    }
}
