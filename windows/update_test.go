package main

import (
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestNewerVersion(t *testing.T) {
	cases := []struct {
		current, candidate string
		want               bool
	}{
		{"0.8.2", "v0.8.3", true},
		{"0.9.9", "v0.10.0", true},
		{"1.0", "v1.0.0", false},
		{"0.9.0", "v0.8.9", false},
		{"dev", "v9.9.9", false},
		{"0.9.0", "v1.0-beta", false},
		{"0.9.0", "", false},
	}
	for _, c := range cases {
		if got := newerVersion(c.current, c.candidate); got != c.want {
			t.Errorf("newerVersion(%q, %q) = %v, want %v", c.current, c.candidate, got, c.want)
		}
	}
}

func TestReceiverAsset(t *testing.T) {
	if receiverAsset("arm64") != "ConectorMWReceiver-arm64.exe" || receiverAsset("amd64") != "ConectorMWReceiver.exe" {
		t.Fatal("wrong asset names")
	}
}

func TestLatestRelease(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/repos/o/conector/releases/latest":
			w.Write([]byte(`{"tag_name":"v0.9.0","html_url":"https://github.com/o/conector/releases/tag/v0.9.0",
				"assets":[{"name":"ConectorMWReceiver.exe","browser_download_url":"https://example.com/a.exe","digest":"sha256:ab"},
				          {"name":"ConectorMWReceiver-arm64.exe","browser_download_url":"http://example.com/b.exe"}]}`))
		case "/repos/o/pre/releases/latest":
			w.Write([]byte(`{"tag_name":"v1.0.0","prerelease":true}`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	latest, err := latestRelease(server.URL, "o/conector")
	if err != nil || latest.Tag != "v0.9.0" {
		t.Fatalf("latest = %+v, %v", latest, err)
	}
	if asset, ok := latest.asset("ConectorMWReceiver.exe"); !ok || asset.Digest != "sha256:ab" {
		t.Fatalf("x64 asset = %+v, %v", asset, ok)
	}
	if _, ok := latest.asset("ConectorMWReceiver-arm64.exe"); ok {
		t.Fatal("plain http asset must be ignored")
	}
	if latest, err := latestRelease(server.URL, "o/pre"); err != nil || latest.Tag != "" {
		t.Fatalf("prerelease = %+v, %v", latest, err)
	}
	if latest, err := latestRelease(server.URL, "o/none"); err != nil || latest.Tag != "" {
		t.Fatalf("missing = %+v, %v", latest, err)
	}
	if _, err := latestRelease(server.URL, ""); err != errNoUpdateRepo {
		t.Fatalf("empty repo err = %v", err)
	}
}

func TestDownloadChecksDigest(t *testing.T) {
	body := []byte("new receiver")
	sum := sha256.Sum256(body)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write(body) }))
	defer server.Close()
	path := filepath.Join(t.TempDir(), "ConectorMWReceiver.exe.new")

	good := releaseAsset{Name: "ConectorMWReceiver.exe", URL: server.URL, Digest: "sha256:" + hex.EncodeToString(sum[:])}
	if err := download(good, path); err != nil {
		t.Fatalf("download: %v", err)
	}
	if data, _ := os.ReadFile(path); string(data) != string(body) {
		t.Fatalf("saved %q", data)
	}

	bad := good
	bad.Digest = "sha256:" + hex.EncodeToString(make([]byte, 32))
	if err := download(bad, path); err == nil {
		t.Fatal("checksum mismatch accepted")
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("bad download left on disk")
	}
	missing := good
	missing.Digest = ""
	if err := download(missing, path); err == nil {
		t.Fatal("asset without digest accepted")
	}
}
