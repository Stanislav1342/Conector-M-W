package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

// version and updateRepo are set at build time with -ldflags -X.
var (
	version    = "dev"
	updateRepo = ""
)

var errNoUpdateRepo = errors.New("update repository is not set in this build")

type releaseAsset struct {
	Name   string `json:"name"`
	URL    string `json:"browser_download_url"`
	Digest string `json:"digest"`
}

type release struct {
	Tag        string         `json:"tag_name"`
	Page       string         `json:"html_url"`
	Draft      bool           `json:"draft"`
	Prerelease bool           `json:"prerelease"`
	Assets     []releaseAsset `json:"assets"`
}

// parseVersion turns "v0.9.1" into [0 9 1]; it rejects anything but dotted numbers.
func parseVersion(text string) ([]int, bool) {
	text = strings.TrimPrefix(strings.TrimPrefix(strings.TrimSpace(text), "v"), "V")
	pieces := strings.Split(text, ".")
	if text == "" || len(pieces) > 4 {
		return nil, false
	}
	parts := make([]int, 0, len(pieces))
	for _, piece := range pieces {
		value, err := strconv.Atoi(piece)
		if err != nil || value < 0 || strings.HasPrefix(piece, "+") {
			return nil, false
		}
		parts = append(parts, value)
	}
	return parts, true
}

// newerVersion reports whether candidate is a higher release than current.
// A development build ("dev") never updates itself.
func newerVersion(current, candidate string) bool {
	have, ok := parseVersion(current)
	want, ok2 := parseVersion(candidate)
	if !ok || !ok2 {
		return false
	}
	for i := 0; i < len(have) || i < len(want); i++ {
		var a, b int
		if i < len(have) {
			a = have[i]
		}
		if i < len(want) {
			b = want[i]
		}
		if a != b {
			return b > a
		}
	}
	return false
}

// receiverAsset is the release file built for this CPU.
func receiverAsset(goarch string) string {
	if goarch == "arm64" {
		return "PriloReceiver-arm64.exe"
	}
	return "PriloReceiver.exe"
}

func (r release) asset(name string) (releaseAsset, bool) {
	for _, asset := range r.Assets {
		if asset.Name == name && strings.HasPrefix(asset.URL, "https://") {
			return asset, true
		}
	}
	return releaseAsset{}, false
}

var updateClient = &http.Client{Timeout: 2 * time.Minute}

// latestRelease asks the GitHub API for the newest published release.
// An empty release means nothing is published yet.
func latestRelease(apiBase, repo string) (release, error) {
	if strings.Count(repo, "/") != 1 {
		return release{}, errNoUpdateRepo
	}
	request, err := http.NewRequest(http.MethodGet, apiBase+"/repos/"+repo+"/releases/latest", nil)
	if err != nil {
		return release{}, err
	}
	request.Header.Set("Accept", "application/vnd.github+json")
	request.Header.Set("User-Agent", "PriloReceiver/"+version)
	response, err := updateClient.Do(request)
	if err != nil {
		return release{}, err
	}
	defer response.Body.Close()
	if response.StatusCode == http.StatusNotFound {
		return release{}, nil
	}
	if response.StatusCode != http.StatusOK {
		return release{}, fmt.Errorf("GitHub answered %d", response.StatusCode)
	}
	var latest release
	if err := json.NewDecoder(io.LimitReader(response.Body, 1<<20)).Decode(&latest); err != nil {
		return release{}, err
	}
	if latest.Draft || latest.Prerelease {
		return release{}, nil
	}
	return latest, nil
}

// download saves the asset to path and checks the SHA-256 digest GitHub publishes for it.
func download(asset releaseAsset, path string) error {
	expected, hasDigest := strings.CutPrefix(asset.Digest, "sha256:")
	if !hasDigest {
		return fmt.Errorf("release asset %s has no sha256 digest", asset.Name)
	}
	request, err := http.NewRequest(http.MethodGet, asset.URL, nil)
	if err != nil {
		return err
	}
	request.Header.Set("User-Agent", "PriloReceiver/"+version)
	response, err := updateClient.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("download answered %d", response.StatusCode)
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o755)
	if err != nil {
		return err
	}
	hash := sha256.New()
	_, copyErr := io.Copy(io.MultiWriter(file, hash), io.LimitReader(response.Body, 200<<20))
	closeErr := file.Close()
	if err := errors.Join(copyErr, closeErr); err != nil {
		os.Remove(path)
		return err
	}
	if got := hex.EncodeToString(hash.Sum(nil)); !strings.EqualFold(got, expected) {
		os.Remove(path)
		return fmt.Errorf("checksum mismatch for %s", asset.Name)
	}
	return nil
}
