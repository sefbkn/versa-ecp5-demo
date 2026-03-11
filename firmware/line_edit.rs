// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Youssef Boukenken

use crate::parse::MAX_LINE_LEN;

const CARRIAGE_RETURN: u8 = b'\r';
const LINE_FEED: u8 = b'\n';
const BACKSPACE: u8 = 0x08;
const DELETE: u8 = 0x7F;

pub enum EditEvent {
    None,
    Echo(u8),
    Backspace,
    LineReady(usize),
    OverflowStarted,
    OverflowFinished,
}

pub struct LineEditor {
    buf: [u8; MAX_LINE_LEN],
    len: usize,
    discarding_overflow: bool,
    prev_was_cr: bool,
}

impl LineEditor {
    pub const fn new() -> Self {
        Self {
            buf: [0; MAX_LINE_LEN],
            len: 0,
            discarding_overflow: false,
            prev_was_cr: false,
        }
    }

    pub fn line(&self, line_len: usize) -> &[u8] {
        let limit = line_len.min(self.buf.len());
        &self.buf[..limit]
    }

    pub fn feed(&mut self, byte: u8) -> EditEvent {
        if self.discarding_overflow {
            return self.feed_overflow(byte);
        }

        if self.is_line_end(byte) {
            if byte == LINE_FEED && self.prev_was_cr {
                self.prev_was_cr = false;
                return EditEvent::None;
            }
            self.prev_was_cr = byte == CARRIAGE_RETURN;
            let line_len = self.len;
            self.len = 0;
            return EditEvent::LineReady(line_len);
        }
        self.prev_was_cr = false;

        if byte == BACKSPACE || byte == DELETE {
            if self.len != 0 {
                self.len -= 1;
                return EditEvent::Backspace;
            }
            return EditEvent::None;
        }

        if self.len == self.buf.len() {
            self.len = 0;
            self.discarding_overflow = true;
            return EditEvent::OverflowStarted;
        }

        if byte.is_ascii_graphic() || byte == b' ' {
            if let Some(slot) = self.buf.get_mut(self.len) {
                *slot = byte;
                self.len += 1;
                return EditEvent::Echo(byte);
            }
        }

        EditEvent::None
    }

    fn feed_overflow(&mut self, byte: u8) -> EditEvent {
        if !self.is_line_end(byte) {
            return EditEvent::None;
        }

        if byte == LINE_FEED && self.prev_was_cr {
            self.prev_was_cr = false;
            return EditEvent::None;
        }

        self.prev_was_cr = byte == CARRIAGE_RETURN;
        self.discarding_overflow = false;
        self.len = 0;
        EditEvent::OverflowFinished
    }

    fn is_line_end(&self, byte: u8) -> bool {
        byte == CARRIAGE_RETURN || byte == LINE_FEED
    }
}
