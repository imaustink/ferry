package main

// Framing for the link between ferry-streamer and ferry-cri.
//
// Both directions carry several logical streams over one connection, so each
// message is tagged:
//
//	[1 byte channel][4 bytes big-endian length][payload]
//
// It mirrors the channel model Kubernetes already uses for exec, which keeps
// the translation on both ends trivial.

import (
	"encoding/binary"
	"fmt"
	"io"
)

type channel byte

const (
	chStdin  channel = 0
	chStdout channel = 1
	chStderr channel = 2
	chExit   channel = 3 // payload: one byte, the exit status
	chResize channel = 4 // payload: JSON {"width":w,"height":h}
)

const maxFrame = 1 << 20

func writeFrame(w io.Writer, c channel, payload []byte) error {
	header := make([]byte, 5)
	header[0] = byte(c)
	binary.BigEndian.PutUint32(header[1:], uint32(len(payload)))
	if _, err := w.Write(header); err != nil {
		return err
	}
	if len(payload) == 0 {
		return nil
	}
	_, err := w.Write(payload)
	return err
}

func readFrame(r io.Reader) (channel, []byte, error) {
	header := make([]byte, 5)
	if _, err := io.ReadFull(r, header); err != nil {
		return 0, nil, err
	}
	length := binary.BigEndian.Uint32(header[1:])
	if length > maxFrame {
		return 0, nil, fmt.Errorf("frame of %d bytes exceeds the %d byte limit", length, maxFrame)
	}
	if length == 0 {
		return channel(header[0]), nil, nil
	}
	payload := make([]byte, length)
	if _, err := io.ReadFull(r, payload); err != nil {
		return 0, nil, err
	}
	return channel(header[0]), payload, nil
}
