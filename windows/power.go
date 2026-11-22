package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"
)

type powerController struct {
	mu       sync.Mutex
	last     time.Time
	shutdown func() error
}

func powerToken(inputToken string) string {
	mac := hmac.New(sha256.New, []byte(inputToken))
	mac.Write([]byte("prilo-power-v1"))
	return hex.EncodeToString(mac.Sum(nil))
}

func (p *powerController) register(mux *http.ServeMux, token string) {
	mux.HandleFunc("/power/status", func(w http.ResponseWriter, req *http.Request) {
		if req.Method != http.MethodGet {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		if !authorized(req, token) {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("/power/shutdown", func(w http.ResponseWriter, req *http.Request) {
		if req.Method != http.MethodPost {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		if !authorized(req, token) {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		p.mu.Lock()
		defer p.mu.Unlock()
		if time.Since(p.last) >= 10*time.Second {
			if err := p.shutdown(); err != nil {
				log.Printf("Power shutdown request failed: %v", err)
				w.WriteHeader(http.StatusServiceUnavailable)
				return
			}
			p.last = time.Now()
		}
		w.WriteHeader(http.StatusAccepted)
	})
}

func shutdownWindows() error {
	root := os.Getenv("SystemRoot")
	if !filepath.IsAbs(root) {
		return fmt.Errorf("Windows system directory is unavailable")
	}
	return exec.Command(filepath.Join(root, "System32", "shutdown.exe"), "/s", "/t", "0").Run()
}
