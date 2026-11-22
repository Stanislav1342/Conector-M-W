package main

import (
	"io"
	"log"
	"os"
	"path/filepath"
)

const logLimit = 256 << 10

// logPath is %LOCALAPPDATA%\Prilo\receiver.log on Windows.
func logPath() string {
	dir, err := os.UserCacheDir()
	if err != nil {
		dir = os.TempDir()
	}
	return filepath.Join(dir, "Prilo", "receiver.log")
}

// setupLog sends the standard logger to the log file, keeping one previous file.
// The receiver has no console, so this is the only place errors are recorded.
func setupLog() func() {
	path := logPath()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return func() {}
	}
	if info, err := os.Stat(path); err == nil && info.Size() > logLimit {
		_ = os.Rename(path, path+".1")
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return func() {}
	}
	log.SetOutput(io.MultiWriter(file, os.Stderr))
	log.SetFlags(log.LstdFlags)
	return func() { _ = file.Close() }
}
