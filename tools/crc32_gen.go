// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Youssef Boukenken

// This package writes the generated crc_next() function body for the reusable
// Ethernet CRC-32 RTL checker to stdout. The emitted CRC update equations are
// mechanically derived from the IEEE 802.3 reflected CRC-32 polynomial.

package main

import (
	"bufio"
	"fmt"
	"io"
	"math/bits"
	"os"
	"strings"
)

const (
	polyReflected uint32 = 0xEDB88320
	crcInit       uint32 = 0xFFFFFFFF
	crcXorOut     uint32 = 0xFFFFFFFF
	crc32Check    uint32 = 0xCBF43926 // CRC-32/IEEE check for "123456789"
	eqWidth       uint32 = 32
	dataWidth     uint32 = 8
)

type equationSet [eqWidth]uint64

func generateEquations() equationSet {
	// Source variables are packed into a 40-bit mask:
	// c[0..31] -> bits 0..31, d[0..7] -> bits 32..39.
	var state equationSet
	for i := range eqWidth {
		state[i] = uint64(1) << i
	}

	// Process d[0]..d[7] (LSB-first reflected CRC update).
	for bit := range dataWidth {
		feedback := state[0] ^ (uint64(1) << (eqWidth + bit))

		var next equationSet
		copy(next[:eqWidth-1], state[1:])
		next[eqWidth-1] = 0

		for i := range eqWidth {
			if ((polyReflected >> i) & 1) != 0 {
				next[i] ^= feedback
			}
		}
		state = next
	}

	return state
}

func formatTerms(mask uint64) string {
	terms := make([]string, 0, eqWidth+dataWidth)
	for i := range eqWidth {
		if ((mask >> i) & 1) != 0 {
			terms = append(terms, fmt.Sprintf("c[%d]", i))
		}
	}
	for i := range dataWidth {
		if ((mask >> (eqWidth + i)) & 1) != 0 {
			terms = append(terms, fmt.Sprintf("d[%d]", i))
		}
	}
	return strings.Join(terms, " ^ ")
}

func stepReflectedCRC32(crc uint32, data uint8) uint32 {
	crc ^= uint32(data)
	for range dataWidth {
		if (crc & 1) != 0 {
			crc = (crc >> 1) ^ polyReflected
		} else {
			crc >>= 1
		}
	}
	return crc
}

func evalEquations(eq equationSet, c uint32, d uint8) uint32 {
	src := uint64(c) | (uint64(d) << eqWidth)
	var out uint32
	for bit := range eqWidth {
		if (bits.OnesCount64(eq[bit]&src) & 1) != 0 {
			out |= uint32(1) << bit
		}
	}
	return out
}

func verify(eq equationSet) error {
	// Known-answer vectors for one-byte digest from Ethernet CRC init state.
	// key: input value (uint32), value: raw CRC state after digesting that byte.
	// For this check, keys must be in [0x00..0xFF].
	knownByteCRC := map[uint32]uint32{
		0x00000000: 0x2DFD1072,
		0x00000001: 0x5AFA20E4,
		0x00000055: 0x36FCB509,
		0x000000AA: 0x1BFE5A84,
		0x000000FF: 0x00FFFFFF,
	}

	for d32, want := range knownByteCRC {
		if d32 > 0xFF {
			return fmt.Errorf("known-answer key out of byte range: 0x%08X", d32)
		}
		d := uint8(d32)

		gotRef := stepReflectedCRC32(crcInit, d)
		if gotRef != want {
			return fmt.Errorf("known-answer mismatch ref d=0x%08X want=0x%08X got=0x%08X", d32, want, gotRef)
		}

		gotEq := evalEquations(eq, crcInit, d)
		if gotEq != want {
			return fmt.Errorf("known-answer mismatch eq d=0x%08X want=0x%08X got=0x%08X", d32, want, gotEq)
		}
	}

	// Canonical stream check (CRC-32/IEEE): "123456789" -> 0xCBF43926
	payload := []byte("123456789")
	rawRef := crcInit
	rawEq := crcInit
	for _, b := range payload {
		rawRef = stepReflectedCRC32(rawRef, b)
		rawEq = evalEquations(eq, rawEq, b)
	}
	if rawEq != rawRef {
		return fmt.Errorf("stream mismatch raw_ref=0x%08X raw_eq=0x%08X", rawRef, rawEq)
	}

	finalCRC := rawEq ^ crcXorOut
	if finalCRC != crc32Check {
		return fmt.Errorf("stream check mismatch final=0x%08X want=0x%08X", finalCRC, crc32Check)
	}

	return nil
}

func writeVerilog(w io.Writer, eq equationSet) error {
	bw := bufio.NewWriter(w)
	lines := []string{
		"// Generated XOR matrix for 8-bit parallel reflected CRC-32 update,",
		"// mechanically derived from IEEE 802.3 CRC-32 polynomial 0xEDB88320.",
		"// Each crc_next[i] is the XOR of selected bits from the current CRC",
		"// state and input data byte. The selected bits are derived from the",
		"// polynomial feedback structure.",
		"function [31:0] crc_next;",
		"    input [31:0] c; // current CRC state",
		"    input [7:0]  d; // input data byte",
		"    begin",
	}

	for bit := range eqWidth {
		pad := " "
		if bit < 10 {
			pad = "  "
		}
		lines = append(lines, fmt.Sprintf("        crc_next[%d]%s= %s;", bit, pad, formatTerms(eq[bit])))
	}

	lines = append(lines,
		"    end",
		"endfunction",
	)

	if _, err := io.WriteString(bw, strings.Join(lines, "\n")+"\n"); err != nil {
		return err
	}
	return bw.Flush()
}

func main() {
	eq := generateEquations()
	if err := verify(eq); err != nil {
		fmt.Fprintln(os.Stderr, fmt.Errorf("crc32_gen: %w", err))
		os.Exit(1)
	}

	if err := writeVerilog(os.Stdout, eq); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
