// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Youssef Boukenken

pub const MAX_LINE_LEN: usize = 128;
pub const MAX_TOKENS: usize = 8;
pub const MAX_TOKEN_LEN: usize = 15;

#[derive(Clone, Copy, Eq, PartialEq)]
pub enum TokenizeError {
    TokenTooLong,
    TooManyTokens,
}

#[derive(Clone, Copy, Eq, PartialEq)]
pub struct Token {
    start: usize,
    end: usize,
}

impl Token {
    const EMPTY: Self = Self { start: 0, end: 0 };
}

pub struct Tokens {
    spans: [Token; MAX_TOKENS],
    count: usize,
}

impl Tokens {
    pub const fn new() -> Self {
        Self {
            spans: [Token::EMPTY; MAX_TOKENS],
            count: 0,
        }
    }

    pub fn is_empty(&self) -> bool {
        self.count == 0
    }

    pub fn count(&self) -> usize {
        self.count
    }

    pub fn is(&self, line: &[u8], idx: usize, lit: &[u8]) -> bool {
        if idx >= self.count {
            return false;
        }

        match line.get(self.spans[idx].start..self.spans[idx].end) {
            Some(tok) => tok == lit,
            None => false,
        }
    }

    fn push(&mut self, token: Token) -> Result<(), TokenizeError> {
        if self.count == self.spans.len() {
            return Err(TokenizeError::TooManyTokens);
        }

        if let Some(slot) = self.spans.get_mut(self.count) {
            *slot = token;
        }
        self.count += 1;
        Ok(())
    }
}

#[inline(always)]
fn is_space(c: u8) -> bool {
    c == b' '
}

pub fn tokenize(line: &[u8]) -> Result<Tokens, TokenizeError> {
    let mut tokens = Tokens::new();
    let mut token_start = None;

    for (pos, &c) in line.iter().enumerate() {
        if is_space(c) {
            if let Some(start) = token_start.take() {
                if (pos - start) > MAX_TOKEN_LEN {
                    return Err(TokenizeError::TokenTooLong);
                }
                tokens.push(Token { start, end: pos })?;
            }
        } else if token_start.is_none() {
            token_start = Some(pos);
        }
    }

    if let Some(start) = token_start {
        let end = line.len();
        if (end - start) > MAX_TOKEN_LEN {
            return Err(TokenizeError::TokenTooLong);
        }
        tokens.push(Token { start, end })?;
    }

    Ok(tokens)
}
