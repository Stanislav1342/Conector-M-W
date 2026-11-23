package main

import (
	"fmt"
	"runtime"
	"syscall"
	"time"
	"unicode/utf16"
	"unsafe"
)

const (
	cfUnicodeText = 13
	gmemMoveable  = 0x0002
)

var (
	kernel32                   = syscall.NewLazyDLL("kernel32.dll")
	globalAlloc                = kernel32.NewProc("GlobalAlloc")
	globalLock                 = kernel32.NewProc("GlobalLock")
	globalUnlock               = kernel32.NewProc("GlobalUnlock")
	globalSize                 = kernel32.NewProc("GlobalSize")
	globalFree                 = kernel32.NewProc("GlobalFree")
	rtlMoveMemory              = kernel32.NewProc("RtlMoveMemory")
	getClipboardSequenceProc   = user32.NewProc("GetClipboardSequenceNumber")
	isClipboardFormatAvailable = user32.NewProc("IsClipboardFormatAvailable")
	openClipboard              = user32.NewProc("OpenClipboard")
	closeClipboard             = user32.NewProc("CloseClipboard")
	emptyClipboard             = user32.NewProc("EmptyClipboard")
	getClipboardData           = user32.NewProc("GetClipboardData")
	setClipboardData           = user32.NewProc("SetClipboardData")
)

func getClipboardSequenceNumber() uint32 {
	seq, _, _ := getClipboardSequenceProc.Call()
	return uint32(seq)
}

func openClipboardWithRetry() error {
	var lastErr error
	for attempt := 0; attempt < 5; attempt++ {
		if ok, _, err := openClipboard.Call(0); ok != 0 {
			return nil
		} else {
			lastErr = err
		}
		time.Sleep(15 * time.Millisecond)
	}
	return fmt.Errorf("OpenClipboard: %v", lastErr)
}

func getClipboardText() (string, bool, error) {
	avail, _, _ := isClipboardFormatAvailable.Call(cfUnicodeText)
	if avail == 0 {
		return "", false, nil
	}
	if err := openClipboardWithRetry(); err != nil {
		return "", false, err
	}
	defer closeClipboard.Call()

	hMem, _, err := getClipboardData.Call(cfUnicodeText)
	if hMem == 0 {
		if availNow, _, _ := isClipboardFormatAvailable.Call(cfUnicodeText); availNow == 0 {
			return "", false, nil
		}
		return "", false, fmt.Errorf("GetClipboardData: %v", err)
	}
	size, _, _ := globalSize.Call(hMem)
	if size < 2 {
		return "", false, nil
	}
	nChars := int(size / 2)
	maxChars := maxClipboardBytes + 1
	truncated := false
	if nChars > maxChars {
		nChars = maxChars
		truncated = true
	}
	src, _, err := globalLock.Call(hMem)
	if src == 0 {
		return "", false, fmt.Errorf("GlobalLock: %v", err)
	}
	buf := make([]uint16, nChars)
	rtlMoveMemory.Call(uintptr(unsafe.Pointer(&buf[0])), src, uintptr(nChars*2))
	runtime.KeepAlive(buf)
	globalUnlock.Call(hMem)

	hasNul := false
	for _, u := range buf {
		if u == 0 {
			hasNul = true
			break
		}
	}
	if truncated && !hasNul {
		return "", false, nil
	}
	text := syscall.UTF16ToString(buf)
	if len(text) == 0 || len(text) > maxClipboardBytes {
		return "", false, nil
	}
	return text, true, nil
}

func setClipboardText(text string) error {
	encoded := utf16.Encode([]rune(text))
	encoded = append(encoded, 0)
	byteLen := len(encoded) * 2
	hMem, _, err := globalAlloc.Call(gmemMoveable, uintptr(byteLen))
	if hMem == 0 {
		return fmt.Errorf("GlobalAlloc: %v", err)
	}
	dst, _, err := globalLock.Call(hMem)
	if dst == 0 {
		globalFree.Call(hMem)
		return fmt.Errorf("GlobalLock: %v", err)
	}
	rtlMoveMemory.Call(dst, uintptr(unsafe.Pointer(&encoded[0])), uintptr(byteLen))
	runtime.KeepAlive(encoded)
	globalUnlock.Call(hMem)

	if err := openClipboardWithRetry(); err != nil {
		globalFree.Call(hMem)
		return err
	}
	defer closeClipboard.Call()

	if ok, _, err := emptyClipboard.Call(); ok == 0 {
		globalFree.Call(hMem)
		return fmt.Errorf("EmptyClipboard: %v", err)
	}
	if res, _, err := setClipboardData.Call(cfUnicodeText, hMem); res == 0 {
		globalFree.Call(hMem)
		return fmt.Errorf("SetClipboardData: %v", err)
	}
	return nil
}
