package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"syscall"
	"unsafe"
)

type dataBlob struct {
	size uint32
	data *byte
}

var crypt32 = syscall.NewLazyDLL("crypt32.dll")
var protectData = crypt32.NewProc("CryptProtectData")
var unprotectData = crypt32.NewProc("CryptUnprotectData")
var localFree = syscall.NewLazyDLL("kernel32.dll").NewProc("LocalFree")

func transformPairing(procedure *syscall.LazyProc, data []byte) ([]byte, error) {
	if len(data) == 0 {
		return nil, fmt.Errorf("empty pairing file")
	}
	input := dataBlob{size: uint32(len(data)), data: &data[0]}
	var output dataBlob
	const forbidUI = 1
	ok, _, err := procedure.Call(uintptr(unsafe.Pointer(&input)), 0, 0, 0, 0, forbidUI, uintptr(unsafe.Pointer(&output)))
	runtime.KeepAlive(data)
	if ok == 0 {
		return nil, err
	}
	defer localFree.Call(uintptr(unsafe.Pointer(output.data)))
	return append([]byte(nil), unsafe.Slice(output.data, int(output.size))...), nil
}

func loadPairing() (pairing, error) {
	root, err := os.UserConfigDir()
	if err != nil {
		return pairing{}, err
	}
	directory := filepath.Join(root, "Prilo")
	path := filepath.Join(directory, "pairing.dat")
	encrypted, err := os.ReadFile(path)
	if err == nil {
		plain, err := transformPairing(unprotectData, encrypted)
		if err != nil {
			return pairing{}, fmt.Errorf("decrypt pairing: %w", err)
		}
		var saved pairing
		err = json.Unmarshal(plain, &saved)
		return saved, err
	}
	if !os.IsNotExist(err) {
		return pairing{}, err
	}

	cert, key, err := certificate()
	if err != nil {
		return pairing{}, err
	}
	var secret [16]byte
	if _, err := rand.Read(secret[:]); err != nil {
		return pairing{}, err
	}
	created := pairing{Certificate: cert, PrivateKey: key, Token: hex.EncodeToString(secret[:])}
	plain, err := json.Marshal(created)
	if err != nil {
		return pairing{}, err
	}
	encrypted, err = transformPairing(protectData, plain)
	if err != nil {
		return pairing{}, fmt.Errorf("encrypt pairing: %w", err)
	}
	if err := os.MkdirAll(directory, 0700); err != nil {
		return pairing{}, err
	}
	file, err := os.CreateTemp(directory, "pairing-*")
	if err != nil {
		return pairing{}, err
	}
	defer os.Remove(file.Name())
	_, writeErr := file.Write(encrypted)
	closeErr := file.Close()
	if writeErr != nil {
		return pairing{}, writeErr
	}
	if closeErr != nil {
		return pairing{}, closeErr
	}
	if err := os.Rename(file.Name(), path); err != nil {
		return pairing{}, err
	}
	return created, nil
}
