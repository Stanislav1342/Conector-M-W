package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"log"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
)

type inputFrame struct {
	Type      string `json:"type,omitempty"`
	Capture   uint64
	Events    []event
	Clipboard string `json:"clipboard,omitempty"`
	Image     string `json:"image,omitempty"`
	Awake     *bool  `json:"awake,omitempty"`
	Action    string `json:"action,omitempty"`
}

type streamMessage struct {
	Type    string `json:"type"`
	Capture uint64 `json:"capture,omitempty"`
	Text    string `json:"text,omitempty"`
	Image   string `json:"image,omitempty"`
}

func validEvents(events []event) bool {
	if events == nil || len(events) > 256 {
		return false
	}
	for _, e := range events {
		if !e.valid() {
			return false
		}
	}
	return true
}

func (r *receiver) releaseAll() {
	r.mu.Lock()
	r.release()
	r.mu.Unlock()
}

func inputStream(r *receiver, control *sync.Mutex, token string) http.HandlerFunc {
	return inputStreamContext(context.Background(), r, control, token)
}

func inputStreamContext(ctx context.Context, r *receiver, control *sync.Mutex, token string) http.HandlerFunc {
	upgrader := websocket.Upgrader{HandshakeTimeout: 3 * time.Second}
	return func(w http.ResponseWriter, req *http.Request) {
		if !authorized(req, token) {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		if !control.TryLock() {
			w.WriteHeader(http.StatusConflict)
			return
		}
		defer control.Unlock()
		ws, err := upgrader.Upgrade(w, req, nil)
		if err != nil {
			return
		}
		defer ws.Close()
		streamCtx, stopStream := context.WithCancel(ctx)
		defer stopStream()
		stopClosing := context.AfterFunc(streamCtx, func() { _ = ws.Close() })
		defer stopClosing()
		defer r.releaseAll()
		ws.SetReadLimit(12 << 20)
		var writeMu sync.Mutex
		write := func(message streamMessage) error {
			writeMu.Lock()
			defer writeMu.Unlock()
			deadline := time.Second
			if message.Type == "clipboardImage" {
				deadline = 5 * time.Second
			}
			_ = ws.SetWriteDeadline(time.Now().Add(deadline))
			return ws.WriteJSON(message)
		}
		if write(streamMessage{Type: "ready"}) != nil {
			return
		}
		clip := newClipboardBridge()
		var keepAwake atomic.Bool
		pushClipboard := func() {
			if item, ok := clip.pollLocal(); ok {
				switch item.kind {
				case "text":
					_ = write(streamMessage{Type: "clipboard", Text: item.text})
				case "image":
					_ = write(streamMessage{
						Type:  "clipboardImage",
						Image: base64.StdEncoding.EncodeToString(item.image),
					})
				}
			}
		}
		go func() {
			clipTicker := time.NewTicker(250 * time.Millisecond)
			awakeTicker := time.NewTicker(25 * time.Second)
			defer clipTicker.Stop()
			defer awakeTicker.Stop()
			for {
				select {
				case <-streamCtx.Done():
					return
				case <-clipTicker.C:
					pushClipboard()
				case <-awakeTicker.C:
					if keepAwake.Load() {
						pulseKeepAwake()
					}
				}
			}
		}()
		var capture uint64
		for {
			readTimeout := 12 * time.Second
			if capture != 0 {
				readTimeout = 2 * time.Second
			}
			_ = ws.SetReadDeadline(time.Now().Add(readTimeout))
			kind, data, err := ws.ReadMessage()
			if err != nil {
				return
			}
			var frame inputFrame
			if (kind != websocket.TextMessage && kind != websocket.BinaryMessage) ||
				json.Unmarshal(data, &frame) != nil {
				_ = write(streamMessage{Type: "invalid"})
				return
			}
			switch frame.Type {
			case "clipboard":
				if len(frame.Clipboard) <= maxClipboardBytes {
					if err := clip.applyRemote(frame.Clipboard); err != nil {
						log.Printf("clipboard apply: %v", err)
					}
				}
				continue
			case "clipboardImage":
				if len(frame.Image) > 0 && len(frame.Image) <= base64.StdEncoding.EncodedLen(maxClipboardImageBytes) {
					pngBytes, err := base64.StdEncoding.DecodeString(frame.Image)
					if err == nil && len(pngBytes) > 0 && len(pngBytes) <= maxClipboardImageBytes {
						if err := clip.applyRemoteImage(pngBytes); err != nil {
							log.Printf("clipboard image apply: %v", err)
						}
					}
				}
				continue
			case "awake":
				if frame.Awake != nil {
					prev := keepAwake.Swap(*frame.Awake)
					if *frame.Awake && !prev {
						pulseKeepAwake()
					}
				}
				continue
			case "shortcut":
				if capture != 0 && frame.Capture == capture && validShortcutAction(frame.Action) {
					r.mu.Lock()
					if !r.stopped {
						r.last = time.Now()
						if err := sendShortcut(frame.Action); err != nil {
							log.Printf("stream shortcut %s: %v", frame.Action, err)
						}
					}
					r.mu.Unlock()
				}
				continue
			}
			if !validEvents(frame.Events) {
				_ = write(streamMessage{Type: "invalid"})
				return
			}
			if len(frame.Events) == 0 {
				_, _ = r.apply(frame.Events)
				continue
			}
			if frame.Capture == 0 {
				continue
			}
			first := frame.Events[0].Kind
			if first == "enter" {
				r.releaseAll()
				capture = frame.Capture
			}
			if frame.Capture != capture {
				continue
			}
			returned, err := r.apply(frame.Events)
			if err != nil {
				log.Printf("stream input: %v", err)
				_ = write(streamMessage{Type: "inputUnavailable", Capture: capture})
				return
			}
			if returned || first == "release" {
				pushClipboard()
				if returned && write(streamMessage{Type: "returned", Capture: capture}) != nil {
					return
				}
				capture = 0
			} else if first == "enter" {
				if write(streamMessage{Type: "entered", Capture: capture}) != nil {
					return
				}
			}
		}
	}
}
