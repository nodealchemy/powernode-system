package federation

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

// Handler completes the first-run federation accept handshake. Created
// with NewHandler; invoked via Run which is intended to be called
// once per agent boot (idempotency comes from the marker file).
type Handler struct {
	// Client is the HTTP client to use for the accept POST. If nil,
	// a default 30-second-timeout client is created.
	Client *http.Client
	// MarkerPath is where the success marker file is written. After
	// a successful accept, this file's presence short-circuits future
	// Run calls. Defaults to "/var/lib/powernode-agent/federation-accepted".
	MarkerPath string
	// CABundlePEM, when non-empty, augments the HTTP client's trusted
	// CA roots with these PEM-encoded certs. Used to trust the
	// parent's mTLS-issuing CA when the parent isn't on the public
	// Web PKI. Only honored when Client is nil (we build the client).
	CABundlePEM string
	// Logf is called for log lines. Defaults to a no-op so the package
	// is silent unless the caller wires it up.
	Logf func(format string, args ...any)
}

// AcceptRequest is the JSON body the child POSTs to
// /api/v1/system/federation_api/accept. Matches the parent-side
// Api::V1::System::FederationApi::AcceptController#create params.
type AcceptRequest struct {
	AcceptanceToken string         `json:"acceptance_token"`
	ContractVersion int            `json:"contract_version"`
	ExtensionSlugs  []string       `json:"extension_slugs,omitempty"`
	Capabilities    map[string]any `json:"capabilities,omitempty"`
	Endpoints       []Endpoint     `json:"endpoints,omitempty"`
}

// Endpoint mirrors the endpoint advertisement schema the parent's
// AcceptController persists into peer.endpoints.
type Endpoint struct {
	URL       string `json:"url"`
	Scope     string `json:"scope"`
	Priority  int    `json:"priority"`
	CIDRHint  string `json:"cidr_hint,omitempty"`
}

// AcceptResponse is the body the parent's AcceptController returns
// on a successful handshake.
type AcceptResponse struct {
	Success bool `json:"success"`
	Data    struct {
		PeerID                string `json:"peer_id"`
		Status                string `json:"status"`
		PeerKind              string `json:"peer_kind"`
		ContractVersionAgreed int    `json:"contract_version_agreed"`
		AcceptedAt            string `json:"accepted_at,omitempty"`
		HandshakeAt           string `json:"handshake_at,omitempty"`
	} `json:"data"`
	Error string `json:"error,omitempty"`
}

// DefaultMarkerPath is where the success marker lives. Once written,
// the handshake is considered complete and subsequent Run calls
// short-circuit. Operators clear this file to force a re-handshake
// (rarely needed; mostly for debugging a stuck spawn).
const DefaultMarkerPath = "/var/lib/powernode-agent/federation-accepted"

// NewHandler constructs a Handler with sensible defaults.
func NewHandler() *Handler {
	return &Handler{
		MarkerPath: DefaultMarkerPath,
		Logf:       func(string, ...any) {},
	}
}

// Run completes the federation handshake. Behavior:
//
//   - If the marker file already exists, returns nil immediately
//     (handshake done; idempotent).
//   - If LoadConfig returns ErrNotConfigured, returns nil (this child
//     wasn't spawned via federation; legitimate steady-state).
//   - Otherwise, POSTs to <parent_url>/api/v1/system/federation_api/accept
//     and on 2xx writes the marker file.
//
// A non-nil error means the handshake actively failed (network error,
// non-2xx response, marker write failure). Callers should retry with
// backoff; the bootstrap token's TTL is hours so retries within that
// window are well within tolerance.
func (h *Handler) Run(ctx context.Context, cfg *Config) error {
	if h.Logf == nil {
		h.Logf = func(string, ...any) {}
	}
	if h.MarkerPath == "" {
		h.MarkerPath = DefaultMarkerPath
	}

	if alreadyDone(h.MarkerPath) {
		h.Logf("federation: marker present at %s; skipping handshake", h.MarkerPath)
		return nil
	}

	if cfg == nil {
		return errors.New("federation: nil config")
	}
	if cfg.ParentURL == "" || cfg.AcceptanceToken == "" {
		return errors.New("federation: parent_url and acceptance_token required")
	}

	client := h.Client
	if client == nil {
		c, err := buildClient(h.CABundlePEM)
		if err != nil {
			return fmt.Errorf("federation: build http client: %w", err)
		}
		client = c
	}

	body := AcceptRequest{
		AcceptanceToken: cfg.AcceptanceToken,
		ContractVersion: contractVersionInt(cfg.ContractVersion),
		Capabilities:    map[string]any{},
		ExtensionSlugs:  []string{},
		Endpoints:       []Endpoint{},
	}

	endpoint := fmt.Sprintf("%s/api/v1/system/federation_api/accept", trimRightSlash(cfg.ParentURL))
	h.Logf("federation: POST %s (spawn_mode=%s, parent_peer_id=%s)",
		endpoint, cfg.SpawnMode, cfg.ParentPeerID)

	respData, err := h.postJSON(ctx, client, endpoint, body)
	if err != nil {
		return err
	}

	if !respData.Success {
		return fmt.Errorf("federation: parent rejected accept: %s", respData.Error)
	}

	if err := writeMarker(h.MarkerPath, respData); err != nil {
		return fmt.Errorf("federation: write marker: %w", err)
	}

	h.Logf("federation: handshake complete peer_id=%s status=%s",
		respData.Data.PeerID, respData.Data.Status)
	return nil
}

// postJSON marshals body, POSTs it, and decodes the response. Returns
// a descriptive error on transport failure or non-2xx response.
func (h *Handler) postJSON(ctx context.Context, client *http.Client, endpoint string, body AcceptRequest) (*AcceptResponse, error) {
	payload, err := json.Marshal(body)
	if err != nil {
		return nil, fmt.Errorf("marshal accept body: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(payload))
	if err != nil {
		return nil, fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", "powernode-agent/federation")

	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("POST %s: %w", endpoint, err)
	}
	defer resp.Body.Close()

	respBytes, _ := io.ReadAll(io.LimitReader(resp.Body, 64*1024))

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("federation accept HTTP %d: %s", resp.StatusCode, string(respBytes))
	}

	var parsed AcceptResponse
	if err := json.Unmarshal(respBytes, &parsed); err != nil {
		return nil, fmt.Errorf("decode response: %w (body=%s)", err, string(respBytes))
	}
	return &parsed, nil
}

// alreadyDone returns true when the marker file exists at path.
// Any read error other than ENOENT is treated as "not done" — the
// caller will attempt the handshake again, which is safe because
// the marker write itself is the success signal.
func alreadyDone(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// writeMarker atomically writes the marker file (tmp + rename) with a
// short JSON summary of the accept result so operators can inspect
// the success without reading platform-side audit logs.
func writeMarker(path string, resp *AcceptResponse) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	summary := map[string]any{
		"peer_id":                  resp.Data.PeerID,
		"status":                   resp.Data.Status,
		"peer_kind":                resp.Data.PeerKind,
		"contract_version_agreed":  resp.Data.ContractVersionAgreed,
		"accepted_at":              resp.Data.AcceptedAt,
		"handshake_at":             resp.Data.HandshakeAt,
		"marker_written_at":        time.Now().UTC().Format(time.RFC3339),
	}
	data, _ := json.MarshalIndent(summary, "", "  ")

	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// buildClient constructs an http.Client that trusts the parent's CA
// bundle (when supplied). A 30s timeout is applied to the entire
// request including TLS handshake.
func buildClient(caBundlePEM string) (*http.Client, error) {
	transport := http.DefaultTransport.(*http.Transport).Clone()

	if caBundlePEM != "" {
		pool, err := x509.SystemCertPool()
		if err != nil || pool == nil {
			pool = x509.NewCertPool()
		}
		if !pool.AppendCertsFromPEM([]byte(caBundlePEM)) {
			return nil, errors.New("invalid CA bundle PEM")
		}
		if transport.TLSClientConfig == nil {
			transport.TLSClientConfig = &tls.Config{RootCAs: pool}
		} else {
			transport.TLSClientConfig.RootCAs = pool
		}
	}

	return &http.Client{
		Timeout:   30 * time.Second,
		Transport: transport,
	}, nil
}

func trimRightSlash(s string) string {
	for len(s) > 0 && s[len(s)-1] == '/' {
		s = s[:len(s)-1]
	}
	return s
}

// contractVersionInt parses a v1/V1/"1" version string to int. Falls
// back to 1 if unparseable so the handshake can proceed against a
// v1-capable parent even with a sloppy fw-cfg value.
func contractVersionInt(s string) int {
	// Strip a leading "v" or "V" if present.
	if len(s) > 0 && (s[0] == 'v' || s[0] == 'V') {
		s = s[1:]
	}
	var n int
	for _, ch := range s {
		if ch < '0' || ch > '9' {
			break
		}
		n = n*10 + int(ch-'0')
	}
	if n == 0 {
		return 1
	}
	return n
}
