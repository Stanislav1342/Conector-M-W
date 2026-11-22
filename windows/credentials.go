package main

import (
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"fmt"
)

type pairing struct {
	Certificate []byte
	PrivateKey  []byte
	Token       string
}

func (p pairing) credentials() (tls.Certificate, string, error) {
	cert, err := tls.X509KeyPair(p.Certificate, p.PrivateKey)
	if err != nil {
		return tls.Certificate{}, "", err
	}
	token, err := hex.DecodeString(p.Token)
	if err != nil || len(token) != 16 {
		return tls.Certificate{}, "", fmt.Errorf("invalid stored access code")
	}
	hash := sha256.Sum256(cert.Certificate[0])
	return cert, hex.EncodeToString(hash[:]), nil
}
