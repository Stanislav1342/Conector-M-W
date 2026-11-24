//go:build !windows

package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"image"
	"image/color"
	"image/png"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

type streamHarness struct {
	t       *testing.T
	r       *receiver
	server  *httptest.Server
	control *sync.Mutex
}

func newStream(t *testing.T) *streamHarness {
	t.Helper()
	resetFake(t)
	h := &streamHarness{t: t, r: newReceiver(), control: &sync.Mutex{}}
	h.server = httptest.NewServer(inputStream(h.r, h.control, testToken))
	t.Cleanup(h.server.Close)
	return h
}

func (h *streamHarness) dial(token string) (*websocket.Conn, *http.Response, error) {
	header := http.Header{}
	if token != "" {
		header.Set("Authorization", "Bearer "+token)
	}
	return websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(h.server.URL, "http"), header)
}

func (h *streamHarness) connect() *websocket.Conn {
	h.t.Helper()
	ws, _, err := h.dial(testToken)
	if err != nil {
		h.t.Fatal(err)
	}
	h.t.Cleanup(func() { ws.Close() })
	if got := h.read(ws); got.Type != "ready" {
		h.t.Fatalf("first message %+v, want ready", got)
	}
	return ws
}

func (h *streamHarness) read(ws *websocket.Conn) streamMessage {
	h.t.Helper()
	var message streamMessage
	_ = ws.SetReadDeadline(time.Now().Add(2 * time.Second))
	if err := ws.ReadJSON(&message); err != nil {
		h.t.Fatalf("read: %v", err)
	}
	return message
}

func (h *streamHarness) send(ws *websocket.Conn, frame inputFrame) {
	h.t.Helper()
	if err := ws.WriteJSON(frame); err != nil {
		h.t.Fatal(err)
	}
}

// waitFor polls until cond holds; the handler applies frames on its own goroutine.
func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func (h *streamHarness) held(code uint16) bool {
	h.r.mu.Lock()
	defer h.r.mu.Unlock()
	return h.r.keys[code]
}

func TestStreamRequiresToken(t *testing.T) {
	h := newStream(t)
	_, resp, err := h.dial("ffffffffffffffffffffffffffffffff")
	if err == nil || resp == nil || resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("wrong token: err=%v resp=%v, want 401", err, resp)
	}
}

func TestStreamAllowsOneController(t *testing.T) {
	h := newStream(t)
	h.connect()
	_, resp, err := h.dial(testToken)
	if err == nil || resp == nil || resp.StatusCode != http.StatusConflict {
		t.Fatalf("second controller: err=%v resp=%v, want 409", err, resp)
	}
}

func TestStreamEnterAndInput(t *testing.T) {
	h := newStream(t)
	ws := h.connect()
	h.send(ws, inputFrame{Capture: 7, Events: []event{{Kind: "enter", X: 100}}})
	if got := h.read(ws); got.Type != "entered" || got.Capture != 7 {
		t.Fatalf("got %+v, want entered for capture 7", got)
	}
	h.send(ws, inputFrame{Capture: 7, Events: []event{{Kind: "key", Code: 0x1e, Down: true}}})
	waitFor(t, "key held", func() bool { return h.held(0x1e) })
}

func TestStreamIgnoresStaleCapture(t *testing.T) {
	h := newStream(t)
	ws := h.connect()
	h.send(ws, inputFrame{Capture: 2, Events: []event{{Kind: "enter"}}})
	h.read(ws)
	h.send(ws, inputFrame{Capture: 1, Events: []event{{Kind: "key", Code: 0x10, Down: true}}})
	h.send(ws, inputFrame{Capture: 0, Events: []event{{Kind: "key", Code: 0x11, Down: true}}})
	h.send(ws, inputFrame{Capture: 2, Events: []event{{Kind: "key", Code: 0x12, Down: true}}})
	waitFor(t, "current capture applied", func() bool { return h.held(0x12) })
	if h.held(0x10) || h.held(0x11) {
		t.Fatal("frames from another capture must be dropped")
	}
}

func TestStreamReportsReturn(t *testing.T) {
	h := newStream(t)
	ws := h.connect()
	h.send(ws, inputFrame{Capture: 3, Events: []event{{Kind: "enter"}}})
	h.read(ws)
	h.r.mu.Lock()
	h.r.enteredAt = time.Now().Add(-time.Second)
	h.r.mu.Unlock()
	setBottom(true)
	h.send(ws, inputFrame{Capture: 3, Events: []event{{Kind: "move", Y: 60}}})
	if got := h.read(ws); got.Type != "returned" || got.Capture != 3 {
		t.Fatalf("got %+v, want returned for capture 3", got)
	}
}

func TestStreamRejectsInvalidFrame(t *testing.T) {
	h := newStream(t)
	ws := h.connect()
	h.send(ws, inputFrame{Capture: 1, Events: []event{{Kind: "key", Code: 0x500}}})
	if got := h.read(ws); got.Type != "invalid" {
		t.Fatalf("got %+v, want invalid", got)
	}
	_ = ws.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, _, err := ws.ReadMessage(); err == nil {
		t.Fatal("connection must close after an invalid frame")
	}
}

func TestStreamReportsInputFailure(t *testing.T) {
	h := newStream(t)
	ws := h.connect()
	h.send(ws, inputFrame{Capture: 4, Events: []event{{Kind: "enter"}}})
	h.read(ws)
	fake.mu.Lock()
	fake.err = errFake
	fake.mu.Unlock()
	h.send(ws, inputFrame{Capture: 4, Events: []event{{Kind: "move", X: 1}}})
	if got := h.read(ws); got.Type != "inputUnavailable" {
		t.Fatalf("got %+v, want inputUnavailable", got)
	}
}

func TestStreamDisconnectReleasesKeys(t *testing.T) {
	h := newStream(t)
	ws := h.connect()
	h.send(ws, inputFrame{Capture: 5, Events: []event{{Kind: "enter"}, {Kind: "key", Code: 0x1d, Down: true}}})
	h.read(ws)
	waitFor(t, "ctrl held", func() bool { return h.held(0x1d) })
	ws.Close()
	waitFor(t, "ctrl released after disconnect", func() bool { return !h.held(0x1d) })
	// The controller slot must be free again.
	waitFor(t, "control unlocked", func() bool {
		if h.control.TryLock() {
			h.control.Unlock()
			return true
		}
		return false
	})
}

func TestStoppingHostedStreamClosesSocketAndReleasesInput(t *testing.T) {
	resetFake(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	h := &streamHarness{t: t, r: newReceiver(), control: &sync.Mutex{}}
	h.server = httptest.NewServer(inputStreamContext(ctx, h.r, h.control, testToken))
	defer h.server.Close()
	ws := h.connect()
	h.send(ws, inputFrame{Capture: 1, Events: []event{{Kind: "enter"}, {Kind: "key", Code: 30, Down: true}}})
	if got := h.read(ws); got.Type != "entered" || !h.held(30) {
		t.Fatalf("expected captured key, got %+v", got)
	}
	cancel()
	_ = ws.SetReadDeadline(time.Now().Add(time.Second))
	if _, _, err := ws.ReadMessage(); err == nil {
		t.Fatal("hosted stream did not close")
	}
	waitFor(t, "released key", func() bool { return !h.held(30) })
}

func TestStreamClipboardMacToWindows(t *testing.T) {
	h := newStream(t)
	ws := h.connect()
	h.send(ws, inputFrame{Type: "clipboard", Clipboard: "line1\nline2"})
	waitFor(t, "clipboard written on Windows", func() bool {
		return fakeClipboard() == "line1\r\nline2"
	})
	// Applying remote clipboard must not echo back to Mac.
	_ = ws.SetReadDeadline(time.Now().Add(350 * time.Millisecond))
	var extra streamMessage
	if err := ws.ReadJSON(&extra); err == nil {
		t.Fatalf("unexpected echo message: %+v", extra)
	}
}

func TestStreamClipboardWindowsToMac(t *testing.T) {
	h := newStream(t)
	ws := h.connect()
	setFakeClipboard("hello\r\nworld")
	got := h.read(ws)
	if got.Type != "clipboard" || got.Text != "hello\nworld" {
		t.Fatalf("got %+v, want clipboard with normalized LF text", got)
	}
}

func TestStreamClipboardIgnoresOversizedPayload(t *testing.T) {
	h := newStream(t)
	ws := h.connect()
	oversized := strings.Repeat("a", maxClipboardBytes+1)
	h.send(ws, inputFrame{Type: "clipboard", Clipboard: oversized})
	h.send(ws, inputFrame{Capture: 1, Events: []event{{Kind: "enter"}}})
	if got := h.read(ws); got.Type != "entered" {
		t.Fatalf("got %+v, want entered", got)
	}
	if fakeClipboard() != "" {
		t.Fatal("oversized clipboard must be ignored")
	}
}

func samplePNG(t *testing.T) []byte {
	t.Helper()
	img := image.NewNRGBA(image.Rect(0, 0, 2, 2))
	img.SetNRGBA(0, 0, color.NRGBA{R: 255, G: 0, B: 0, A: 255})
	img.SetNRGBA(1, 0, color.NRGBA{R: 0, G: 255, B: 0, A: 255})
	img.SetNRGBA(0, 1, color.NRGBA{R: 0, G: 0, B: 255, A: 255})
	img.SetNRGBA(1, 1, color.NRGBA{R: 0, G: 0, B: 0, A: 0})
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func TestClipboardPNGAndDIBRoundTrip(t *testing.T) {
	pngData := samplePNG(t)
	dib, err := pngToDIB(pngData)
	if err != nil {
		t.Fatalf("pngToDIB: %v", err)
	}
	outPNG, err := dibToPNG(dib)
	if err != nil {
		t.Fatalf("dibToPNG: %v", err)
	}
	decoded, err := png.Decode(bytes.NewReader(outPNG))
	if err != nil {
		t.Fatalf("png.Decode: %v", err)
	}
	// Bottom-right transparent pixel was composited over white in DIB.
	r, g, b, _ := decoded.At(1, 1).RGBA()
	if r>>8 != 255 || g>>8 != 255 || b>>8 != 255 {
		t.Fatalf("transparent pixel composite = (%d,%d,%d), want white", r>>8, g>>8, b>>8)
	}
	// All-zero alpha 32-bit DIB (like Windows PrintScreen) must decode as opaque.
	dibZeroAlpha := append([]byte(nil), dib...)
	for i := 40; i+3 < len(dibZeroAlpha); i += 4 {
		dibZeroAlpha[i+3] = 0
	}
	opaquePNG, err := dibToPNG(dibZeroAlpha)
	if err != nil {
		t.Fatalf("dibToPNG zero alpha: %v", err)
	}
	opaqueImg, err := png.Decode(bytes.NewReader(opaquePNG))
	if err != nil {
		t.Fatal(err)
	}
	_, _, _, a := opaqueImg.At(0, 0).RGBA()
	if a>>8 != 255 {
		t.Fatalf("all-zero alpha DIB got alpha=%d, want 255", a>>8)
	}

	// 24-bit bottom-up DIB with odd width (padding check).
	dib24 := make([]byte, 40+4)
	binary.LittleEndian.PutUint32(dib24[0:4], 40)
	binary.LittleEndian.PutUint32(dib24[4:8], 1)
	binary.LittleEndian.PutUint32(dib24[8:12], 1)
	binary.LittleEndian.PutUint16(dib24[12:14], 1)
	binary.LittleEndian.PutUint16(dib24[14:16], 24)
	dib24[40], dib24[41], dib24[42] = 10, 20, 30
	png24, err := dibToPNG(dib24)
	if err != nil {
		t.Fatalf("dibToPNG 24-bit: %v", err)
	}
	img24, err := png.Decode(bytes.NewReader(png24))
	if err != nil {
		t.Fatal(err)
	}
	r24, g24, b24, _ := img24.At(0, 0).RGBA()
	if r24>>8 != 30 || g24>>8 != 20 || b24>>8 != 10 {
		t.Fatalf("24-bit pixel = (%d,%d,%d), want (30,20,10)", r24>>8, g24>>8, b24>>8)
	}
}

func TestStreamClipboardImageSyncAndNoEcho(t *testing.T) {
	h := newStream(t)
	ws := h.connect()
	pngData := samplePNG(t)
	h.send(ws, inputFrame{Type: "clipboardImage", Image: base64.StdEncoding.EncodeToString(pngData)})
	waitFor(t, "image clipboard written on Windows", func() bool {
		return bytes.Equal(fakeClipboardImage(), pngData)
	})
	_ = ws.SetReadDeadline(time.Now().Add(350 * time.Millisecond))
	var extra streamMessage
	if err := ws.ReadJSON(&extra); err == nil {
		t.Fatalf("unexpected echo message: %+v", extra)
	}
}

func TestStreamClipboardImageWindowsToMac(t *testing.T) {
	h := newStream(t)
	ws := h.connect()
	pngData := samplePNG(t)
	setFakeClipboardImage(pngData)
	got := h.read(ws)
	if got.Type != "clipboardImage" {
		t.Fatalf("got %+v, want clipboardImage", got)
	}
	decoded, err := base64.StdEncoding.DecodeString(got.Image)
	if err != nil || !bytes.Equal(decoded, pngData) {
		t.Fatalf("decoded image mismatch err=%v", err)
	}
}

func TestStreamAwakeFramePulsesKeepAwake(t *testing.T) {
	h := newStream(t)
	ws := h.connect()
	on := true
	h.send(ws, inputFrame{Type: "awake", Awake: &on})
	waitFor(t, "keep-awake pulse", func() bool {
		return awakePulses() >= 1
	})
}

func TestShortcutCombos(t *testing.T) {
	expectedCounts := map[string]int{
		"desktopNext":    3,
		"desktopPrev":    3,
		"taskView":       2,
		"showDesktop":    2,
		"switchAppNext":  2,
		"switchAppPrev":  3,
		"browserForward": 2,
		"browserBack":    2,
	}
	for action, wantLen := range expectedCounts {
		if !validShortcutAction(action) {
			t.Fatalf("%s should be valid", action)
		}
		keys, ok := shortcutCombo(action)
		if !ok || len(keys) != wantLen {
			t.Fatalf("%s combo ok=%v len=%d, want %d", action, ok, len(keys), wantLen)
		}
	}
	if validShortcutAction("unknown") {
		t.Fatal("unknown shortcut should be invalid")
	}
	next, _ := shortcutCombo("desktopNext")
	if !next[1].extended || next[1].vk != 0x5B || !next[2].extended || next[2].vk != 0x27 {
		t.Fatalf("desktopNext must mark Win and Right arrow as extended: %+v", next)
	}
	prev, _ := shortcutCombo("desktopPrev")
	if !prev[1].extended || prev[1].vk != 0x5B || !prev[2].extended || prev[2].vk != 0x25 {
		t.Fatalf("desktopPrev must mark Win and Left arrow as extended: %+v", prev)
	}
}

func TestStreamShortcut(t *testing.T) {
	h := newStream(t)
	ws := h.connect()
	h.send(ws, inputFrame{Type: "shortcut", Capture: 1, Action: "desktopNext"})
	h.send(ws, inputFrame{Capture: 4, Events: []event{{Kind: "enter", X: 100}}})
	if got := h.read(ws); got.Type != "entered" || got.Capture != 4 {
		t.Fatalf("got %+v, want entered for capture 4", got)
	}
	h.send(ws, inputFrame{Type: "shortcut", Capture: 3, Action: "desktopPrev"})
	h.send(ws, inputFrame{Type: "shortcut", Capture: 4, Action: "unknown"})
	h.send(ws, inputFrame{Type: "shortcut", Capture: 4, Action: "desktopNext"})
	h.send(ws, inputFrame{Type: "shortcut", Capture: 4, Action: "showDesktop"})
	waitFor(t, "two valid shortcuts", func() bool {
		return len(sentShortcuts()) == 2
	})
	got := sentShortcuts()
	if got[0] != "desktopNext" || got[1] != "showDesktop" {
		t.Fatalf("shortcuts = %v, want [desktopNext showDesktop]", got)
	}
	// Stream must still accept events after invalid/stale shortcut frames.
	h.send(ws, inputFrame{Capture: 4, Events: []event{{Kind: "key", Code: 0x1e, Down: true}}})
	waitFor(t, "key held after shortcut", func() bool { return h.held(0x1e) })
}

func TestDeviceInfoAdvertisesShortcutSupport(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/device", nil)
	req.Header.Set("Authorization", "Bearer "+testToken)
	rec := httptest.NewRecorder()
	deviceInfo(testToken)(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	var info map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &info); err != nil {
		t.Fatal(err)
	}
	if info["stream"] != "1" || info["shortcut"] != "1" {
		t.Fatalf("info = %+v, want stream=1 and shortcut=1", info)
	}
}
