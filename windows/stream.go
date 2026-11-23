package main

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

type inputFrame struct {
	Capture uint64
	Events  []event
}

type streamMessage struct {
	Type    string `json:"type"`
	Capture uint64 `json:"capture,omitempty"`
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
		stopClosing := context.AfterFunc(ctx, func() { _ = ws.Close() })
		defer stopClosing()
		defer r.releaseAll()
		ws.SetReadLimit(32768)
		write := func(message streamMessage) error {
			_ = ws.SetWriteDeadline(time.Now().Add(time.Second))
			return ws.WriteJSON(message)
		}
		if write(streamMessage{Type: "ready"}) != nil {
			return
		}
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
				json.Unmarshal(data, &frame) != nil || !validEvents(frame.Events) {
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
