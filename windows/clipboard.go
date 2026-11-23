package main

import (
	"strings"
	"sync"
)

const maxClipboardBytes = 512 << 10

func normalizeClipboardNewlines(text string) string {
	text = strings.ReplaceAll(text, "\r\n", "\n")
	return strings.ReplaceAll(text, "\r", "\n")
}

func windowsClipboardNewlines(text string) string {
	canonical := strings.ReplaceAll(normalizeClipboardNewlines(text), "\x00", "")
	return strings.ReplaceAll(canonical, "\n", "\r\n")
}

type clipboardBridge struct {
	mu       sync.Mutex
	lastSeq  uint32
	lastText string
}

func newClipboardBridge() *clipboardBridge {
	return &clipboardBridge{lastSeq: getClipboardSequenceNumber()}
}

func (b *clipboardBridge) applyRemote(text string) error {
	if len(text) == 0 || len(text) > maxClipboardBytes {
		return nil
	}
	canonical := strings.ReplaceAll(normalizeClipboardNewlines(text), "\x00", "")
	if canonical == "" || len(canonical) > maxClipboardBytes {
		return nil
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if err := setClipboardText(windowsClipboardNewlines(canonical)); err != nil {
		return err
	}
	b.lastText = canonical
	b.lastSeq = getClipboardSequenceNumber()
	return nil
}

func (b *clipboardBridge) pollLocal() (string, bool) {
	seq := getClipboardSequenceNumber()
	b.mu.Lock()
	unchanged := seq == b.lastSeq
	b.mu.Unlock()
	if unchanged {
		return "", false
	}

	raw, ok, err := getClipboardText()
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.lastSeq == seq {
		return "", false
	}
	if err != nil {
		return "", false
	}
	b.lastSeq = seq
	if !ok || len(raw) == 0 || len(raw) > maxClipboardBytes {
		b.lastText = ""
		return "", false
	}
	canonical := strings.ReplaceAll(normalizeClipboardNewlines(raw), "\x00", "")
	if canonical == "" || len(canonical) > maxClipboardBytes || canonical == b.lastText {
		return "", false
	}
	b.lastText = canonical
	return canonical, true
}
