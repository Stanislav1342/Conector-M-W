package main

import (
	"crypto/rand"
	"encoding/hex"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

const (
	maxFileUploadBytes    int64 = 512 << 20
	maxClipboardFileBytes int64 = 25 << 20
	maxClipboardFileCount       = 20
)

type offeredFile struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Size int64  `json:"size"`
	path string
}

type fileStore struct {
	mu         sync.Mutex
	files      map[string]offeredFile
	batches    map[string][]string
	batchOrder []string
}

func newFileStore() *fileStore {
	return &fileStore{
		files:   make(map[string]offeredFile),
		batches: make(map[string][]string),
	}
}

func (s *fileStore) register(paths []string) []offeredFile {
	next := make(map[string]offeredFile)
	out := make([]offeredFile, 0, len(paths))
	seen := make(map[string]bool)
	for _, rawPath := range paths {
		if len(out) >= maxClipboardFileCount {
			break
		}
		clean := filepath.Clean(rawPath)
		if clean == "" || seen[clean] {
			continue
		}
		seen[clean] = true
		info, err := os.Stat(clean)
		if err != nil || !info.Mode().IsRegular() || info.Size() < 0 || info.Size() > maxFileUploadBytes {
			continue
		}
		var token [16]byte
		if _, err := rand.Read(token[:]); err != nil {
			continue
		}
		id := hex.EncodeToString(token[:])
		entry := offeredFile{
			ID:   id,
			Name: sanitizeFilename(filepath.Base(clean)),
			Size: info.Size(),
			path: clean,
		}
		next[id] = entry
		out = append(out, entry)
	}
	s.mu.Lock()
	s.files = next
	s.mu.Unlock()
	return out
}

func (s *fileStore) lookup(id string) (offeredFile, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	entry, ok := s.files[id]
	return entry, ok
}

func (s *fileStore) recordBatch(batchID, filePath string) []string {
	if batchID == "" {
		return []string{filePath}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, exists := s.batches[batchID]; !exists {
		s.batchOrder = append(s.batchOrder, batchID)
		for len(s.batchOrder) > 16 {
			oldest := s.batchOrder[0]
			s.batchOrder = s.batchOrder[1:]
			delete(s.batches, oldest)
		}
	}
	s.batches[batchID] = append(s.batches[batchID], filePath)
	out := make([]string, len(s.batches[batchID]))
	copy(out, s.batches[batchID])
	return out
}

var windowsReservedNames = map[string]bool{
	"CON": true, "PRN": true, "AUX": true, "NUL": true,
	"COM1": true, "COM2": true, "COM3": true, "COM4": true, "COM5": true,
	"COM6": true, "COM7": true, "COM8": true, "COM9": true,
	"LPT1": true, "LPT2": true, "LPT3": true, "LPT4": true, "LPT5": true,
	"LPT6": true, "LPT7": true, "LPT8": true, "LPT9": true,
}

func truncateUTF8(s string, maxBytes int) string {
	if maxBytes <= 0 {
		return ""
	}
	if len(s) <= maxBytes {
		return s
	}
	bytesUsed := 0
	for idx, r := range s {
		w := utf8.RuneLen(r)
		if w < 0 || bytesUsed+w > maxBytes {
			return s[:idx]
		}
		bytesUsed += w
	}
	return s
}

func sanitizeFilename(raw string) string {
	if unescaped, err := url.PathUnescape(raw); err == nil {
		raw = unescaped
	}
	raw = strings.ReplaceAll(raw, "\\", "/")
	if idx := strings.LastIndex(raw, "/"); idx >= 0 {
		raw = raw[idx+1:]
	}
	var b strings.Builder
	for _, r := range raw {
		if r < 0x20 || strings.ContainsRune(`<>:"/\|?*`, r) {
			b.WriteByte('_')
		} else {
			b.WriteRune(r)
		}
	}
	cleaned := strings.TrimRight(strings.TrimSpace(b.String()), ". ")
	cleaned = strings.TrimLeft(cleaned, ". ")
	if cleaned == "" || cleaned == "." || cleaned == ".." {
		return "file"
	}
	stem := cleaned
	if dot := strings.IndexByte(cleaned, '.'); dot >= 0 {
		stem = cleaned[:dot]
	}
	if windowsReservedNames[strings.ToUpper(stem)] {
		cleaned = "_" + cleaned
	}
	if len(cleaned) > 180 {
		ext := ""
		if dot := strings.LastIndexByte(cleaned, '.'); dot > 0 && len(cleaned)-dot <= 32 {
			ext = cleaned[dot:]
			base := truncateUTF8(cleaned[:dot], 180-len(ext))
			base = strings.TrimRight(base, ". ")
			if base == "" {
				base = "file"
			}
			cleaned = base + ext
		} else {
			cleaned = truncateUTF8(cleaned, 180)
			cleaned = strings.TrimRight(cleaned, ". ")
		}
	}
	if cleaned == "" {
		return "file"
	}
	return cleaned
}

func uniqueFilePath(dir, name string) (string, string, error) {
	candidate := filepath.Join(dir, name)
	if _, err := os.Lstat(candidate); os.IsNotExist(err) {
		return candidate, name, nil
	} else if err != nil {
		return "", "", err
	}
	ext := filepath.Ext(name)
	stem := strings.TrimSuffix(name, ext)
	if stem == "" {
		stem = "file"
	}
	for n := 2; n < 10000; n++ {
		nextName := stem + " (" + strconv.Itoa(n) + ")" + ext
		nextPath := filepath.Join(dir, nextName)
		if _, err := os.Lstat(nextPath); os.IsNotExist(err) {
			return nextPath, nextName, nil
		} else if err != nil {
			return "", "", err
		}
	}
	return "", "", os.ErrExist
}

func cleanupTempClipboardFiles(dir string, maxAge time.Duration) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	cutoff := time.Now().Add(-maxAge)
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			continue
		}
		if info.Mode().IsRegular() && info.ModTime().Before(cutoff) {
			_ = os.Remove(filepath.Join(dir, entry.Name()))
		}
	}
}

func handleFileUpload(token string, clip *clipboardBridge, store *fileStore, resolveDir func(string) (string, error)) http.HandlerFunc {
	return func(w http.ResponseWriter, req *http.Request) {
		if req.Method != http.MethodPost {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		if !authorized(req, token) {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		rc := http.NewResponseController(w)
		_ = rc.SetReadDeadline(time.Now().Add(10 * time.Minute))
		_ = rc.SetWriteDeadline(time.Now().Add(10 * time.Minute))

		name := sanitizeFilename(req.Header.Get("X-Conector-Filename"))
		dest := req.Header.Get("X-Conector-Destination")
		setClipboard := req.Header.Get("X-Conector-Clipboard") != "0"
		batchID := req.Header.Get("X-Conector-Batch")

		dir, err := resolveDir(dest)
		if err != nil {
			log.Printf("file upload dir: %v", err)
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		if err := os.MkdirAll(dir, 0o700); err != nil {
			log.Printf("file upload mkdir: %v", err)
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		if dest == "clipboard" {
			cleanupTempClipboardFiles(dir, 2*time.Hour)
		}

		tmp, err := os.CreateTemp(dir, ".conector-upload-*")
		if err != nil {
			log.Printf("file upload create temp: %v", err)
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		tmpPath := tmp.Name()
		removeTmp := true
		defer func() {
			if removeTmp {
				_ = tmp.Close()
				_ = os.Remove(tmpPath)
			}
		}()

		written, err := io.Copy(tmp, io.LimitReader(req.Body, maxFileUploadBytes+1))
		if err != nil {
			log.Printf("file upload copy: %v", err)
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		if written > maxFileUploadBytes {
			w.WriteHeader(http.StatusRequestEntityTooLarge)
			return
		}
		if err := tmp.Close(); err != nil {
			log.Printf("file upload close: %v", err)
			w.WriteHeader(http.StatusInternalServerError)
			return
		}

		finalPath, finalName, err := uniqueFilePath(dir, name)
		if err != nil {
			log.Printf("file upload unique path: %v", err)
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		if err := os.Rename(tmpPath, finalPath); err != nil {
			log.Printf("file upload rename: %v", err)
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		removeTmp = false

		if setClipboard && clip != nil {
			paths := []string{finalPath}
			if store != nil {
				paths = store.recordBatch(batchID, finalPath)
			}
			if err := clip.applyRemoteFiles(paths); err != nil {
				log.Printf("file upload clipboard: %v", err)
			}
		}

		writeJSON(w, map[string]any{
			"name": finalName,
			"path": finalPath,
			"size": written,
		})
	}
}

func handleFileDownload(token string, store *fileStore) http.HandlerFunc {
	return func(w http.ResponseWriter, req *http.Request) {
		if req.Method != http.MethodGet {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		if !authorized(req, token) {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		rc := http.NewResponseController(w)
		_ = rc.SetWriteDeadline(time.Now().Add(10 * time.Minute))

		if store == nil {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		entry, ok := store.lookup(req.URL.Query().Get("id"))
		if !ok {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		info, err := os.Stat(entry.path)
		if err != nil || !info.Mode().IsRegular() || info.Size() > maxFileUploadBytes {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		f, err := os.Open(entry.path)
		if err != nil {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		defer f.Close()

		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("Content-Length", strconv.FormatInt(info.Size(), 10))
		w.Header().Set("X-Conector-Filename", url.PathEscape(entry.Name))
		w.Header().Set("Cache-Control", "no-store")
		w.WriteHeader(http.StatusOK)
		_, _ = io.Copy(w, f)
	}
}
