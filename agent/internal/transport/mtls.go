// Package transport builds the mTLS HTTP client the agent uses for every
// post-enrollment call to the platform. Loads cert + key + CA bundle
// from the on-disk PKI directory written by the enroll package.
//
// Reference: Golden Eclipse plan M2.E + M0.P (mTLS in node_api/base_controller).
package transport

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/enroll"
)

// Client wraps an http.Client built from on-disk mTLS material.
type Client struct {
	*http.Client
	PlatformURL string
	InstanceID  string
	// InstanceToken is the legacy-path JWT. When non-empty, every request
	// gets `Authorization: Bearer <token>` so the platform can authenticate
	// us before mTLS termination is configured at the reverse proxy.
	InstanceToken string
}

// LoadFromPKIDir reads cert + key + CA bundle from the canonical agent
// PKI directory and returns an mTLS-configured http.Client. Returns an
// error if any required file is missing — first-boot callers should run
// `enroll.Client.Enroll` and `enroll.Save` first.
func LoadFromPKIDir(platformURL string, paths enroll.PKIPaths) (*Client, error) {
	if platformURL == "" {
		return nil, errors.New("LoadFromPKIDir: platformURL required")
	}

	cert, err := tls.LoadX509KeyPair(paths.Cert, paths.Key)
	if err != nil {
		return nil, fmt.Errorf("load cert+key: %w", err)
	}

	caPEM, err := os.ReadFile(paths.CABundle)
	if err != nil {
		return nil, fmt.Errorf("read ca bundle: %w", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(caPEM) {
		return nil, errors.New("ca bundle has no parseable certs")
	}

	tr := &http.Transport{
		TLSClientConfig: &tls.Config{
			Certificates: []tls.Certificate{cert},
			RootCAs:      pool,
			MinVersion:   tls.VersionTLS13,
		},
		ResponseHeaderTimeout: 10 * time.Second,
		// Slice 7d: prefer IPv6 when the platform URL hostname has
		// both AAAA and A records. The default Go resolver doesn't
		// guarantee v6 ordering — we do it explicitly so agent →
		// platform polling stays on the v6 wire whenever possible,
		// falling through to v4 on dial failure.
		DialContext: v6PreferredDialContext,
	}

	httpClient := &http.Client{
		Transport: tr,
		Timeout:   30 * time.Second,
	}

	// Read meta.json for instance_id (best-effort; non-fatal if absent).
	instanceID := readInstanceID(paths.Meta)

	// Read instance JWT (best-effort; absent on pure-mTLS deployments).
	tokenBytes, _ := os.ReadFile(paths.Token)

	return &Client{
		Client:        httpClient,
		PlatformURL:   platformURL,
		InstanceID:    instanceID,
		InstanceToken: trimSpace(string(tokenBytes)),
	}, nil
}

// v6PreferredDialContext resolves the host's IPs, orders v6 before v4,
// and dials in that order. Each attempt has a short timeout so the
// fallback to v4 fires fast on v6 connectivity failure (the typical
// cause of v6→v4 fallback is "v6 path is broken at some hop," not
// "the destination is offline" — give it ~3 seconds and move on).
//
// Slice 7d of the SDWAN plan.
func v6PreferredDialContext(ctx context.Context, network, addr string) (net.Conn, error) {
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		return nil, err
	}

	// If host is already a literal IP, no resolution; default Dialer.
	if ip := net.ParseIP(host); ip != nil {
		return (&net.Dialer{Timeout: 10 * time.Second}).DialContext(ctx, network, addr)
	}

	resolver := net.DefaultResolver
	ips, err := resolver.LookupIPAddr(ctx, host)
	if err != nil {
		return nil, fmt.Errorf("resolve %s: %w", host, err)
	}

	v6 := make([]net.IP, 0, len(ips))
	v4 := make([]net.IP, 0, len(ips))
	for _, ipa := range ips {
		if ipa.IP.To4() == nil {
			v6 = append(v6, ipa.IP)
		} else {
			v4 = append(v4, ipa.IP)
		}
	}

	dialer := &net.Dialer{Timeout: 3 * time.Second} // short per-attempt timeout
	var lastErr error
	for _, ip := range append(v6, v4...) {
		target := net.JoinHostPort(ip.String(), port)
		conn, derr := dialer.DialContext(ctx, network, target)
		if derr == nil {
			return conn, nil
		}
		lastErr = derr
	}
	if lastErr == nil {
		lastErr = fmt.Errorf("no addresses resolved for %s", host)
	}
	return nil, lastErr
}

// trimSpace removes leading/trailing whitespace without pulling strings.
func trimSpace(s string) string {
	start := 0
	for start < len(s) && (s[start] == ' ' || s[start] == '\t' || s[start] == '\n' || s[start] == '\r') {
		start++
	}
	end := len(s)
	for end > start && (s[end-1] == ' ' || s[end-1] == '\t' || s[end-1] == '\n' || s[end-1] == '\r') {
		end--
	}
	return s[start:end]
}

// PostJSON wraps http.Client.Post with JSON content-type + Accept headers.
func (c *Client) PostJSON(path string, body []byte) (*http.Response, error) {
	url := c.PlatformURL + path
	req, err := http.NewRequest(http.MethodPost, url, bytesReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	c.setAuth(req)
	return c.Do(req)
}

// GetJSON wraps http.Client.Get with Accept header.
func (c *Client) GetJSON(path string) (*http.Response, error) {
	req, err := http.NewRequest(http.MethodGet, c.PlatformURL+path, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/json")
	c.setAuth(req)
	return c.Do(req)
}

// setAuth attaches the instance JWT Bearer header when one is loaded. mTLS
// material is already configured on the underlying http.Transport, so this
// is purely additive — the platform's authenticate_instance! tries mTLS
// first, then falls through to the Bearer token. Belt-and-suspenders is the
// right posture during the M0.P transition window.
func (c *Client) setAuth(req *http.Request) {
	if c.InstanceToken != "" {
		req.Header.Set("Authorization", "Bearer "+c.InstanceToken)
	}
}

// readInstanceID extracts "instance_id" from the meta.json sidecar. If
// the file is missing or malformed, returns empty string (the agent
// proceeds with whatever the cert subject claims).
func readInstanceID(metaPath string) string {
	data, err := os.ReadFile(metaPath)
	if err != nil {
		return ""
	}
	// Lightweight parser — meta.json has a flat shape (4 keys); avoid
	// pulling encoding/json's reflection overhead on the boot path.
	const key = `"instance_id":"`
	i := indexOf(data, []byte(key))
	if i < 0 {
		return ""
	}
	rest := data[i+len(key):]
	end := indexOf(rest, []byte(`"`))
	if end < 0 {
		return ""
	}
	return string(rest[:end])
}

func indexOf(haystack, needle []byte) int {
	if len(needle) == 0 || len(needle) > len(haystack) {
		return -1
	}
	for i := 0; i <= len(haystack)-len(needle); i++ {
		match := true
		for j := 0; j < len(needle); j++ {
			if haystack[i+j] != needle[j] {
				match = false
				break
			}
		}
		if match {
			return i
		}
	}
	return -1
}

// bytesReader returns an io.Reader for a byte slice without pulling in
// bytes.NewReader's full surface (keeps the static binary lean).
func bytesReader(b []byte) *byteReader { return &byteReader{b: b} }

type byteReader struct {
	b []byte
	i int
}

func (br *byteReader) Read(p []byte) (n int, err error) {
	if br.i >= len(br.b) {
		return 0, io.EOF
	}
	n = copy(p, br.b[br.i:])
	br.i += n
	return n, nil
}
