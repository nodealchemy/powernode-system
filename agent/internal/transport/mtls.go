// Package transport builds the mTLS HTTP client the agent uses for every
// post-enrollment call to the platform. Loads cert + key + CA bundle
// from the on-disk PKI directory written by the enroll package.
//
// Reference: Golden Eclipse plan M2.E + M0.P (mTLS in node_api/base_controller).
package transport

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/enroll"
)

// Client wraps an http.Client built from on-disk mTLS material.
//
// Auth model: mTLS only. The TLS handshake presents the agent's cert
// (signed by the platform's internal CA); the reverse proxy verifies it
// via `tls.options=mtls-optional@file` (VerifyClientCertIfGiven on the
// single websecure entrypoint) and forwards the CN to Rails via
// X-Forwarded-Tls-Client-Cert-Info. No bearer token, no second auth
// surface — see extensions/system/docs/agent-internals.md.
type Client struct {
	*http.Client
	PlatformURL string
	InstanceID  string
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

	return &Client{
		Client:      httpClient,
		PlatformURL: platformURL,
		InstanceID:  instanceID,
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

// PostJSON wraps http.Client.Post with JSON content-type + Accept headers.
// Auth is purely mTLS — the underlying http.Transport already presents the
// agent's client cert; no Bearer header is sent.
func (c *Client) PostJSON(path string, body []byte) (*http.Response, error) {
	url := c.PlatformURL + path
	// bytes.NewReader (not a hand-rolled io.Reader): http.NewRequest only
	// populates req.GetBody — and a real ContentLength instead of chunked
	// encoding — for the three body types it recognises (*bytes.Buffer,
	// *bytes.Reader, *strings.Reader). Without GetBody a POST cannot be
	// replayed, which would silently exclude the heartbeat (the agent's main
	// mutating call) from Do's 401 retry. `bytes` is already linked into this
	// binary many times over, so the leanness this replaced was not real.
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	return c.Do(req)
}

// GetJSON wraps http.Client.Get with Accept header.
func (c *Client) GetJSON(path string) (*http.Response, error) {
	req, err := http.NewRequest(http.MethodGet, c.PlatformURL+path, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/json")
	return c.Do(req)
}

// Do shadows the embedded http.Client's Do so every caller — GetJSON,
// PostJSON, the heartbeat, the task lease, the reconcilers — self-heals one
// specific, otherwise-permanent failure: a pooled TLS connection that was
// negotiated WITHOUT a client certificate.
//
// How a node gets stuck (ops-hub, 2026-07-26). The reverse proxy learns to
// request client certs from dynamic config that a co-located control plane
// cannot write until its Rails app has booted — ~2 minutes after the node comes
// up. The agent starts polling immediately, so its first handshake completes
// against a proxy that is serving TLS but not yet asking for a certificate. Go
// pools that connection; keep-alives are on and IdleConnTimeout is unset, and
// the agent polls every 10-30s, so the connection is never idle long enough to
// be dropped. Every later request rides it, the platform never sees a client
// cert, and answers 401 forever. Measured: 28 consecutive 401s across ~14
// minutes, on a node whose cert on disk was valid the whole time — `curl` with
// the same files returned 200, because curl opens a fresh connection each run.
// Only `systemctl restart powernode-agent` cleared it.
//
// A 401 is therefore evidence that this connection's handshake is stale, not
// evidence that the identity is bad. Evict the pool and retry once on a fresh
// handshake. If the retry also 401s the rejection is real and is returned
// unchanged, so a genuinely revoked cert still surfaces as 401 — it just costs
// one extra handshake.
func (c *Client) Do(req *http.Request) (*http.Response, error) {
	resp, err := c.Client.Do(req)
	if err != nil || resp == nil || resp.StatusCode != http.StatusUnauthorized {
		return resp, err
	}

	// Only bodyless or replayable requests can be retried. http.NewRequest
	// populates GetBody for the in-memory body types the agent uses, so this
	// covers PostJSON; anything streaming is left alone rather than risking a
	// half-consumed body.
	replay, ok := replayRequest(req)
	if !ok {
		// Cannot retry THIS request, but the connection it rode is still
		// poisoned and would keep failing every future caller. Evict anyway so
		// a non-replayable request degrades to "this one call failed" rather
		// than re-arming the permanent stuck state this whole method exists to
		// prevent. No in-tree caller reaches this today (every agent body is a
		// *bytes.Reader); a future streaming one must not silently lose the
		// self-heal.
		_ = resp.Body.Close()
		c.Client.CloseIdleConnections()
		return resp, nil
	}

	// Close WITHOUT draining, deliberately. Go only returns a connection to the
	// idle pool when its body was read to EOF; closing a partially-read body
	// makes the transport destroy the connection instead. That is exactly what
	// a poisoned connection deserves, and it is the only way to guarantee this
	// request's retry cannot be handed the same connection back.
	//
	// Draining first is the intuitive thing to write and it is WRONG here: it
	// re-pools the bad connection, and a concurrent caller can check it straight
	// back out in the window before CloseIdleConnections runs. Confirmed by
	// TestDoRecoversUnderConcurrentCallers — with a drain, 2-6 of 256 calls
	// still 401 after the proxy starts requesting certs, i.e. the "a second 401
	// means the rejection is real" contract below silently becomes false. The
	// agent runs exactly that shape: heartbeat, task lease, keys syncer and the
	// reconcilers share one Client and poll together.
	_ = resp.Body.Close()
	// Still purge the pool: OTHER goroutines' connections were negotiated in the
	// same certless window and are equally poisoned.
	c.Client.CloseIdleConnections()

	retryResp, retryErr := c.Client.Do(replay)
	if retryErr != nil {
		// Report the transport error; the caller has already lost the original
		// response body, and a dial failure is more actionable than a stale 401.
		return nil, retryErr
	}
	return retryResp, nil
}

// replayRequest clones req for a second attempt, returning ok=false when the
// body cannot be replayed safely.
func replayRequest(req *http.Request) (*http.Request, bool) {
	if req == nil {
		return nil, false
	}
	clone := req.Clone(req.Context())
	if req.Body == nil || req.Body == http.NoBody {
		return clone, true
	}
	if req.GetBody == nil {
		return nil, false
	}
	body, err := req.GetBody()
	if err != nil {
		return nil, false
	}
	clone.Body = body
	return clone, true
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
