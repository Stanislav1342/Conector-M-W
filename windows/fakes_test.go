//go:build !windows

// Test doubles for the Windows-only input layer, so the receiver logic runs on macOS and Linux.
package main

import (
	"sync"
	"testing"
)

var fake struct {
	mu          sync.Mutex
	sent        []event
	failKey     uint16 // key-up for this code fails while non-zero
	err         error  // every send fails while non-nil
	bottom      bool
	clipSeq     uint32
	clipText    string
	clipHasText bool
}

func (e event) send() error {
	fake.mu.Lock()
	defer fake.mu.Unlock()
	if fake.err != nil {
		return fake.err
	}
	if fake.failKey != 0 && e.Kind == "key" && e.Code == fake.failKey && !e.Down {
		return errFake
	}
	fake.sent = append(fake.sent, e)
	return nil
}

func atBottom() bool {
	fake.mu.Lock()
	defer fake.mu.Unlock()
	return fake.bottom
}

func setDPIAware()                  {}
func startupOption() (bool, error)  { return false, nil }
func loadPairing() (pairing, error) { return pairing{}, nil }
func openHappLink(string) error     { return nil }
func showError(string)              {}
func runTray(*trayApp)              {}

type trayApp struct {
	invite  *pairingInvite
	details func() string
	quit    func()
}

var launchedAtLogin, launchedAfterUpdate bool

func cleanupOldExe() {}

type fakeError string

func (e fakeError) Error() string { return string(e) }

const errFake = fakeError("injected send failure")

func getClipboardSequenceNumber() uint32 {
	fake.mu.Lock()
	defer fake.mu.Unlock()
	return fake.clipSeq
}

func getClipboardText() (string, bool, error) {
	fake.mu.Lock()
	defer fake.mu.Unlock()
	if !fake.clipHasText {
		return "", false, nil
	}
	return fake.clipText, true, nil
}

func setClipboardText(text string) error {
	fake.mu.Lock()
	defer fake.mu.Unlock()
	fake.clipSeq++
	fake.clipText = text
	fake.clipHasText = true
	return nil
}

func resetFake(t *testing.T) {
	t.Helper()
	fake.mu.Lock()
	fake.sent, fake.failKey, fake.err, fake.bottom = nil, 0, nil, false
	fake.clipSeq, fake.clipText, fake.clipHasText = 0, "", false
	fake.mu.Unlock()
}

func sentEvents() []event {
	fake.mu.Lock()
	defer fake.mu.Unlock()
	return append([]event(nil), fake.sent...)
}

func setBottom(value bool) {
	fake.mu.Lock()
	fake.bottom = value
	fake.mu.Unlock()
}

func setFakeClipboard(text string) {
	fake.mu.Lock()
	fake.clipSeq++
	fake.clipText = text
	fake.clipHasText = true
	fake.mu.Unlock()
}

func fakeClipboard() string {
	fake.mu.Lock()
	defer fake.mu.Unlock()
	return fake.clipText
}
