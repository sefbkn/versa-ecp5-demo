// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Youssef Boukenken

use core::fmt::{self, Write};

use crate::mdio::{mdio_err_code, mdio_read, mdio_reg_desc, MdioError, Phy};
use crate::parse::{tokenize, TokenizeError, Tokens};
use crate::uart_util::{uart_putc, uart_puts, UartWriter};

enum Command {
    Help,
    PhyDump,
    PhyDumpAll,
}

enum CliError {
    TokenTooLong,
    TooManyArgs,
    HelpArgs,
    PhyDumpArgs,
    PhyDumpIncomplete,
    UnknownCommand,
}

fn put_nl() {
    uart_puts("\r\n");
}

fn put_spaces(count: usize) {
    for _ in 0..count {
        uart_putc(b' ');
    }
}

fn hex_digit(nibble: u8) -> char {
    match nibble & 0x0F {
        0..=9 => (b'0' + (nibble & 0x0F)) as char,
        _ => (b'A' + ((nibble & 0x0F) - 10)) as char,
    }
}

struct Hex8(u8);
struct Hex16(u16);

impl fmt::Display for Hex8 {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("0x")?;
        f.write_char(hex_digit(self.0 >> 4))?;
        f.write_char(hex_digit(self.0))
    }
}

impl fmt::Display for Hex16 {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("0x")?;
        f.write_char(hex_digit((self.0 >> 12) as u8))?;
        f.write_char(hex_digit((self.0 >> 8) as u8))?;
        f.write_char(hex_digit((self.0 >> 4) as u8))?;
        f.write_char(hex_digit(self.0 as u8))
    }
}

struct DumpCell(Result<u16, MdioError>);

impl DumpCell {
    fn display_width(&self) -> usize {
        match self.0 {
            Ok(_) => 6,
            Err(err) => 4 + mdio_err_code(err).len(),
        }
    }
}

impl fmt::Display for DumpCell {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.0 {
            Ok(data) => Hex16(data).fmt(f),
            Err(err) => {
                f.write_str("ERR ")?;
                f.write_str(mdio_err_code(err))
            }
        }
    }
}

fn print_ok(tag: &str) {
    uart_puts("OK ");
    uart_puts(tag);
    put_nl();
}

fn print_error(msg: &str) {
    uart_puts("ERR: ");
    uart_puts(msg);
    put_nl();
}

pub fn print_banner() {
    uart_puts("Versa Ethernet CPU UART CLI\r\n");
    uart_puts("Type ? for help\r\n");
}

pub fn print_prompt() {
    uart_puts("versa> ");
}

fn print_help() {
    uart_puts("Commands:\r\n");
    uart_puts("  help      Show this help\r\n");
    uart_puts("  phy dump      Dump non-zero regs across all pages for both PHYs\r\n");
    uart_puts("  phy dump all  Dump all 32 pages x 32 regs for both PHYs\r\n");
}

fn dump_row_needed(p1: Result<u16, MdioError>, p2: Result<u16, MdioError>) -> bool {
    match (p1, p2) {
        (Ok(0), Ok(0)) => false,
        _ => true,
    }
}

fn phy_dump_summary() -> Result<(), MdioError> {
    uart_puts("PHY MDIO Register Summary\r\n");
    uart_puts("Non-zero register values for both PHYs across pages 0x00-0x1F\r\n");
    uart_puts("\r\n");
    uart_puts("Page  Reg   Value (P1)  Value (P2)\r\n");
    uart_puts("----  ----  ----------  ----------\r\n");

    let mut out = UartWriter;

    for page in 0u8..32 {
        for reg_addr in 0u8..32 {
            let p1 = mdio_read(Phy::Phy1, page, reg_addr);
            let p2 = mdio_read(Phy::Phy2, page, reg_addr);

            if !dump_row_needed(p1, p2) {
                continue;
            }

            let p1_cell = DumpCell(p1);
            let p2_cell = DumpCell(p2);
            let _ = write!(out, "{}  {}  ", Hex8(page), Hex8(reg_addr));
            let _ = write!(out, "{p1_cell}");
            put_spaces(10 - p1_cell.display_width());
            uart_puts("  ");
            let _ = write!(out, "{p2_cell}");
            put_spaces(10 - p2_cell.display_width());
            put_nl();

            if let Err(err) = p1 {
                return Err(err);
            }
            if let Err(err) = p2 {
                return Err(err);
            }
        }
    }

    put_nl();
    Ok(())
}

fn phy_dump_all_one(phy: Phy) -> Result<(), MdioError> {
    let mut out = UartWriter;
    uart_puts("PHY ");
    uart_putc(b'0' + (phy.number() as u8));
    uart_puts(" MDIO Register Dump\r\n");

    for page in 0u8..32 {
        uart_puts("Page ");
        let _ = write!(out, "{}", Hex8(page));
        put_nl();
        uart_puts("Reg   Value       Meaning\r\n");
        uart_puts("----  ----------  ------------------------------\r\n");

        for reg_addr in 0u8..32 {
            let desc = mdio_reg_desc(page, reg_addr);
            let row_result = mdio_read(phy, page, reg_addr);
            let row_cell = DumpCell(row_result);
            let _ = write!(out, "{}  {row_cell}", Hex8(reg_addr));
            put_spaces(10 - row_cell.display_width());
            let _ = write!(out, "  {desc}\r\n");

            if let Err(err) = row_result {
                return Err(err);
            }
        }

        put_nl();
    }

    put_nl();
    Ok(())
}

fn parse_phy_dump(tokens: &Tokens, line: &[u8]) -> Result<Command, CliError> {
    if tokens.count() == 2 && tokens.is(line, 1, b"dump") {
        return Ok(Command::PhyDump);
    }

    if tokens.count() == 3 && tokens.is(line, 1, b"dump") && tokens.is(line, 2, b"all") {
        return Ok(Command::PhyDumpAll);
    }

    Err(CliError::PhyDumpArgs)
}

fn parse_command(tokens: &Tokens, line: &[u8]) -> Result<Command, CliError> {
    if tokens.is(line, 0, b"?") || tokens.is(line, 0, b"help") {
        return if tokens.count() == 1 {
            Ok(Command::Help)
        } else {
            Err(CliError::HelpArgs)
        };
    }

    if tokens.is(line, 0, b"phy") {
        return parse_phy_dump(tokens, line);
    }

    Err(CliError::UnknownCommand)
}

fn exec_phy_dump() -> Result<(), CliError> {
    if phy_dump_summary().is_err() {
        return Err(CliError::PhyDumpIncomplete);
    }
    print_ok("phy.dump");
    Ok(())
}

fn exec_phy_dump_all() -> Result<(), CliError> {
    if phy_dump_all_one(Phy::Phy1).is_err() || phy_dump_all_one(Phy::Phy2).is_err() {
        return Err(CliError::PhyDumpIncomplete);
    }
    print_ok("phy.dump.all");
    Ok(())
}

fn exec_command(command: Command) -> Result<(), CliError> {
    match command {
        Command::Help => {
            print_help();
            print_ok("help");
            Ok(())
        }
        Command::PhyDump => exec_phy_dump(),
        Command::PhyDumpAll => exec_phy_dump_all(),
    }
}

fn print_cli_error(err: CliError) {
    match err {
        CliError::TokenTooLong => print_error("EINVAL token too long"),
        CliError::TooManyArgs => print_error("EINVAL too many args"),
        CliError::HelpArgs => print_error("EINVAL help args"),
        CliError::PhyDumpArgs => print_error("usage phy dump [all]"),
        CliError::PhyDumpIncomplete => print_error("phy.dump incomplete"),
        CliError::UnknownCommand => print_error("unknown cmd (? for help)"),
    }
}

pub fn run_cmd(line: &[u8]) {
    let tokens = match tokenize(line) {
        Ok(tokens) => tokens,
        Err(TokenizeError::TokenTooLong) => {
            print_cli_error(CliError::TokenTooLong);
            return;
        }
        Err(TokenizeError::TooManyTokens) => {
            print_cli_error(CliError::TooManyArgs);
            return;
        }
    };

    if tokens.is_empty() {
        return;
    }

    let command = match parse_command(&tokens, line) {
        Ok(command) => command,
        Err(err) => {
            print_cli_error(err);
            return;
        }
    };

    if let Err(err) = exec_command(command) {
        print_cli_error(err);
    }
}
