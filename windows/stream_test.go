//go:build !windows

package main

import (
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
	h.send(ws, inputFrame{Capture: 3, Events: []event{{Kind: "move", Y: 20}}})
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
