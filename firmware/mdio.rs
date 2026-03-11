// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Youssef Boukenken

use crate::soc_map::{
    MDIO_CTRL, MDIO_CTRL_BUSY, MDIO_CTRL_DONE, MDIO_CTRL_ERROR, MDIO_CTRL_GO, MDIO_CTRL_PAGE_SHIFT,
    MDIO_CTRL_REG_ADDR_SHIFT, MDIO_RDATA,
};

// Exceeds the MDIO executor timeout once translated from phy_mgmt_clk to clk100.
const MDIO_IDLE_TIMEOUT_CYCLES: u32 = 100_000_000;
const MDIO_COMPLETION_TIMEOUT_CYCLES: u32 = 100_000_000;

#[derive(Clone, Copy, Eq, PartialEq)]
pub enum Phy {
    Phy1,
    Phy2,
}

impl Phy {
    pub fn number(self) -> u16 {
        match self {
            Self::Phy1 => 1,
            Self::Phy2 => 2,
        }
    }

    fn mdio_bus_select(self) -> u32 {
        match self {
            Self::Phy1 => 0,
            Self::Phy2 => 1,
        }
    }
}

#[derive(Clone, Copy, Eq, PartialEq)]
pub enum MdioError {
    Bus,
    Timeout,
}

pub fn mdio_read(phy: Phy, page: u8, reg_addr: u8) -> Result<u16, MdioError> {
    wait_for_idle()?;
    let ctrl = MDIO_CTRL_GO
        | (phy.mdio_bus_select() << 2)
        | (((page as u32) & 31) << MDIO_CTRL_PAGE_SHIFT)
        | (((reg_addr as u32) & 31) << MDIO_CTRL_REG_ADDR_SHIFT);
    MDIO_CTRL.write(ctrl);

    for _ in 0..MDIO_COMPLETION_TIMEOUT_CYCLES {
        let status = MDIO_CTRL.read();
        if (status & MDIO_CTRL_DONE) == 0 || (status & MDIO_CTRL_BUSY) != 0 {
            continue;
        }

        if (status & MDIO_CTRL_ERROR) != 0 {
            return Err(MdioError::Bus);
        }

        return Ok((MDIO_RDATA.read() & 0xFFFF) as u16);
    }

    Err(MdioError::Timeout)
}

fn wait_for_idle() -> Result<(), MdioError> {
    for _ in 0..MDIO_IDLE_TIMEOUT_CYCLES {
        if (MDIO_CTRL.read() & MDIO_CTRL_BUSY) == 0 {
            return Ok(());
        }
    }

    Err(MdioError::Timeout)
}

pub fn mdio_err_code(err: MdioError) -> &'static str {
    match err {
        MdioError::Bus => "EIO",
        MdioError::Timeout => "ETIME",
    }
}

pub fn mdio_reg_desc(page: u8, reg: u8) -> &'static str {
    match page {
        0 => match reg {
            0 => "Basic Control (BMCR)",
            1 => "Basic Status (BMSR)",
            2 => "PHY Identifier 1",
            3 => "PHY Identifier 2",
            4 => "Auto-Neg Advertise",
            5 => "Auto-Neg LP Ability",
            6 => "Auto-Neg Expansion",
            7 => "Auto-Neg Next Page TX",
            8 => "Auto-Neg LP Next Page",
            9 => "1000BASE-T Control",
            10 => "1000BASE-T Status",
            11 => "Reserved",
            12 => "Reserved",
            13 => "Reserved",
            14 => "Reserved",
            15 => "Extended Status",
            _ => "Reserved",
        },
        _ => "Reserved",
    }
}
