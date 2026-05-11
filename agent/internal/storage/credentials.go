package storage

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
)

// MountCredsDir is where we stage transient credential files for the
// kernel-mode mount(8) helpers (e.g. CIFS credentials=...). Lives on
// tmpfs so contents never hit persistent disk; mode 0600 per file.
const MountCredsDir = "/run/sdwan/mount-creds"

// FetchCredential calls the node_api credential endpoint and unpacks
// the response envelope. Returns the decoded payload bytes (so the
// caller can write them to a transient file with the right shape for
// the mount type) and the typed payload for inspection.
func FetchCredential(client httpGetter, url string) (*CredentialPayload, []byte, error) {
	resp, err := client.GetJSON(url)
	if err != nil {
		return nil, nil, fmt.Errorf("fetch credential %s: %w", url, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, nil, fmt.Errorf("fetch credential %s: status %d", url, resp.StatusCode)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, nil, fmt.Errorf("read credential body: %w", err)
	}

	// Platform's render_success() wraps the body in {"success": true, "data": {...}}
	var envelope struct {
		Success bool              `json:"success"`
		Data    CredentialPayload `json:"data"`
	}
	if err := json.Unmarshal(body, &envelope); err != nil {
		return nil, nil, fmt.Errorf("parse credential envelope: %w", err)
	}
	return &envelope.Data, body, nil
}

// WriteCIFSCredentialFile writes a CIFS credentials= file at
// /run/sdwan/mount-creds/<credID>.cred with mode 0600. Returns the
// path the agent should pass to mount(8) via credentials=.
func WriteCIFSCredentialFile(credID string, payload *CredentialPayload) (string, error) {
	if err := os.MkdirAll(MountCredsDir, 0o700); err != nil {
		return "", fmt.Errorf("mkdir %s: %w", MountCredsDir, err)
	}
	path := filepath.Join(MountCredsDir, credID+".cred")
	contents := fmt.Sprintf("username=%s\npassword=%s\n", payload.Username, payload.Password)
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		return "", fmt.Errorf("write cifs creds %s: %w", path, err)
	}
	return path, nil
}

// RemoveCredentialFile cleans up a transient credential file on unmount.
func RemoveCredentialFile(credID string) error {
	path := filepath.Join(MountCredsDir, credID+".cred")
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

// httpGetter is the subset of *transport.Client this package needs.
// Mirrors tasks.HTTPClient.
type httpGetter interface {
	GetJSON(path string) (*http.Response, error)
}
