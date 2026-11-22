package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"log"
	"math/big"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

type event struct {
	Kind string
	X, Y int32
	Code uint16
	Down bool
}

type receiver struct {
	mu         sync.Mutex
	last       time.Time
	bottomPush int32
	enteredAt  time.Time
	keys       map[uint16]bool
	buttons    map[uint16]bool
}

func (r *receiver) release() {
	for code := range r.keys {
		if (event{Kind: "key", Code: code}).send() == nil {
			delete(r.keys, code)
		}
	}
	for code := range r.buttons {
		if (event{Kind: "button", Code: code}).send() == nil {
			delete(r.buttons, code)
		}
	}
}

func (r *receiver) apply(events []event) (bool, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.last = time.Now()
	for _, e := range events {
		if e.Kind == "release" {
			r.release()
			continue
		}
		if e.Kind == "enter" {
			r.bottomPush = 0
			r.enteredAt = time.Now()
		}
		if e.Kind == "move" {
			if e.Y > 0 && time.Since(r.enteredAt) >= 200*time.Millisecond && atBottom() {
				r.bottomPush += e.Y
				if r.bottomPush >= 8 {
					r.release()
					return true, nil
				}
			} else if e.Y != 0 {
				r.bottomPush = 0
			}
		}
		if err := e.send(); err != nil {
			return false, err
		}
		var held map[uint16]bool
		switch e.Kind {
		case "key":
			held = r.keys
		case "button":
			held = r.buttons
		}
		if held != nil {
			if e.Down {
				held[e.Code] = true
			} else {
				delete(held, e.Code)
			}
		}
	}
	return false, nil
}

func certificate() ([]byte, []byte, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, err
	}
	serialBound := new(big.Int).Lsh(big.NewInt(1), 128)
	serial, err := rand.Int(rand.Reader, serialBound)
	if err != nil {
		return nil, nil, err
	}
	template := &x509.Certificate{
		SerialNumber: serial,
		NotBefore:    time.Now().Add(-time.Minute),
		NotAfter:     time.Now().AddDate(10, 0, 0),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		return nil, nil, err
	}
	privateKey, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return nil, nil, err
	}
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}),
		pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: privateKey}), nil
}

func (e event) valid() bool {
	switch e.Kind {
	case "release":
		return true
	case "enter":
		return e.X >= 0 && e.X <= 65535
	case "move", "scroll":
		return e.X >= -10000 && e.X <= 10000 && e.Y >= -10000 && e.Y <= 10000
	case "button":
		return e.Code <= 2
	case "key":
		return e.Code > 0 && e.Code <= 0x17f && e.Code != 0x100
	}
	return false
}

func authorized(req *http.Request, token string) bool {
	header := req.Header.Get("Authorization")
	return strings.HasPrefix(header, "Bearer ") &&
		subtle.ConstantTimeCompare([]byte(strings.TrimPrefix(header, "Bearer ")), []byte(token)) == 1
}

// fatal records the error and shows it, since the receiver runs without a console.
func fatal(message string, err error) {
	log.Printf("%s: %v", message, err)
	showError(message + "\n\n" + err.Error())
	os.Exit(1)
}

func main() {
	closeLog := setupLog()
	defer closeLog()
	done, err := startupOption()
	if err != nil {
		fatal("Не удалось выполнить команду", err)
	}
	if done {
		return
	}
	setDPIAware()
	cleanupOldExe()
	listener, err := net.Listen("tcp4", ":43821")
	// After a self-update the previous copy may still be closing its listener.
	for wait := 0; err != nil && launchedAfterUpdate && wait < 40; wait++ {
		time.Sleep(250 * time.Millisecond)
		listener, err = net.Listen("tcp4", ":43821")
	}
	if err != nil {
		fatal("Порт 43821 занят. Возможно, Prilo Receiver уже запущен: проверь значок в трее", err)
	}
	saved, err := loadPairing()
	if err != nil {
		fatal("Не удалось загрузить ключи Prilo", err)
	}
	cert, fingerprint, err := saved.credentials()
	if err != nil {
		fatal("Сохранённые ключи Prilo повреждены", err)
	}
	token := saved.Token
	log.Printf("Prilo receiver %s started (autostart=%v, updated=%v)", version, launchedAtLogin, launchedAfterUpdate)

	name, _ := os.Hostname()
	if name == "" {
		name = "Windows"
	}
	go keepAdvertising(name, fingerprint)
	invite := &pairingInvite{fingerprint: fingerprint}
	if _, err := invite.issue(); err != nil {
		log.Printf("Pairing code: %v", err)
	}

	r := &receiver{keys: make(map[uint16]bool), buttons: make(map[uint16]bool)}
	go func() {
		ticker := time.NewTicker(250 * time.Millisecond)
		defer ticker.Stop()
		for range ticker.C {
			r.mu.Lock()
			if time.Since(r.last) > 2*time.Second {
				r.release()
			}
			r.mu.Unlock()
		}
	}()

	mux := http.NewServeMux()
	var control sync.Mutex
	mux.HandleFunc("/stream", inputStream(r, &control, token))
	mux.HandleFunc("/device", deviceInfo(token))
	invite.register(mux, token)
	power := &powerController{shutdown: shutdownWindows}
	power.register(mux, powerToken(token))
	vpn := &vpnController{open: openHappLink}
	vpn.register(mux, powerToken(token))
	mux.HandleFunc("/input", func(w http.ResponseWriter, req *http.Request) {
		if req.Method != http.MethodPost {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		if !authorized(req, token) {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		var events []event
		err := json.NewDecoder(http.MaxBytesReader(w, req.Body, 32768)).Decode(&events)
		if err != nil || !validEvents(events) {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		if !control.TryLock() {
			w.WriteHeader(http.StatusConflict)
			return
		}
		defer control.Unlock()
		returned, err := r.apply(events)
		if err != nil {
			log.Print(err)
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		if returned {
			w.WriteHeader(http.StatusOK)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
	server := &http.Server{
		Handler: mux, TLSConfig: &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12},
		ReadTimeout: 3 * time.Second, WriteTimeout: 3 * time.Second, IdleTimeout: 15 * time.Second,
	}
	go func() {
		if err := server.ServeTLS(listener, "", ""); !errors.Is(err, http.ErrServerClosed) {
			fatal("Приёмник Prilo остановился", err)
		}
	}()
	runTray(&trayApp{
		invite:  invite,
		details: func() string { return connectionDetails(token, fingerprint) },
		quit: func() {
			r.releaseAll()
			_ = server.Close()
			log.Print("Prilo receiver stopped by user")
		},
	})
}
