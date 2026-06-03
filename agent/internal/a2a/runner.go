// runner.go — wires the A2A MCP server into the agent's service loop. It loads
// the node's mTLS identity (the same NodeInstance cert used for platform
// calls), fetches + trusts the platform's capability-signing public keys
// (node_api/a2a/capability_keys), serves the MCP server, and periodically
// refreshes the trusted keys. Default-OFF: the service only starts this when a
// listen address is configured.
//
// NOTE for live enablement: the node's cert must carry ExtKeyUsageServerAuth in
// addition to ClientAuth (the node acts as both an A2A server and client). If
// the issuing PKI role is client-auth-only, the inbound handshake will be
// rejected by peers — widen the role before turning A2A on in production.

package a2a

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"time"
)

// KeyFetcher pulls the capability-key advertisement. *transport.Client
// satisfies this via its GetJSON method.
type KeyFetcher interface {
	GetJSON(path string) (*http.Response, error)
}

// CapabilityKeysPath is the node_api advertisement endpoint.
const CapabilityKeysPath = "/api/v1/system/node_api/a2a/capability_keys"

type advertisedKey struct {
	Handle       string `json:"handle"`
	PublicKeyB64 string `json:"public_key_b64"`
	Algorithm    string `json:"algorithm"`
}

// RefreshKeys fetches the advertised capability-signing public keys and trusts
// them in the verifier. Returns the count trusted. New keys are added; existing
// handles are refreshed in place (idempotent).
func RefreshKeys(verifier *Verifier, fetcher KeyFetcher) (int, error) {
	resp, err := fetcher.GetJSON(CapabilityKeysPath)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 0, fmt.Errorf("capability_keys status %d", resp.StatusCode)
	}
	raw, _ := io.ReadAll(resp.Body)

	var body struct {
		Data struct {
			Keys []advertisedKey `json:"keys"`
		} `json:"data"`
	}
	if err := json.Unmarshal(raw, &body); err != nil {
		return 0, fmt.Errorf("decode capability_keys: %w", err)
	}
	n := 0
	for _, k := range body.Data.Keys {
		if k.Handle == "" || k.PublicKeyB64 == "" {
			continue
		}
		if err := verifier.TrustKey(k.Handle, k.PublicKeyB64); err == nil {
			n++
		}
	}
	return n, nil
}

// RunnerConfig configures the A2A server runner.
type RunnerConfig struct {
	SelfInstanceID  string // = the node's cert CN; token `aud` is matched against it
	ListenAddr      string // e.g. ":7777" or an overlay address
	CertFile        string // node leaf cert (PEM) — presented as the A2A server cert
	KeyFile         string // node private key (PEM)
	CABundleFile    string // platform node-issuing CA chain (PEM) — verifies peer certs
	Registry        *Registry
	Fetcher         KeyFetcher
	RefreshInterval time.Duration // default 5m
	OnError         func(error)
}

// Run loads mTLS material, trusts the advertised capability keys, and serves
// the A2A MCP server until ctx is cancelled. Blocks; run in a goroutine.
func Run(ctx context.Context, cfg RunnerConfig) error {
	if cfg.RefreshInterval <= 0 {
		cfg.RefreshInterval = 5 * time.Minute
	}
	if cfg.Registry == nil {
		return fmt.Errorf("a2a: nil registry")
	}

	verifier := NewVerifier()
	if _, err := RefreshKeys(verifier, cfg.Fetcher); err != nil {
		// Non-fatal — keys can arrive on the next refresh; until then the
		// server rejects every call as an untrusted signer.
		reportErr(cfg.OnError, fmt.Errorf("a2a: initial capability key fetch: %w", err))
	}

	serverCert, err := tls.LoadX509KeyPair(cfg.CertFile, cfg.KeyFile)
	if err != nil {
		return fmt.Errorf("a2a: load node cert: %w", err)
	}
	caPool, err := loadCAPool(cfg.CABundleFile)
	if err != nil {
		return fmt.Errorf("a2a: load CA bundle: %w", err)
	}

	server := NewServer(cfg.SelfInstanceID, verifier, cfg.Registry)
	httpSrv := &http.Server{
		Handler:           server.Handler(),
		TLSConfig:         ServerTLSConfig(serverCert, caPool),
		ReadHeaderTimeout: 10 * time.Second,
	}

	ln, err := net.Listen("tcp", cfg.ListenAddr)
	if err != nil {
		return fmt.Errorf("a2a: listen %s: %w", cfg.ListenAddr, err)
	}

	go cfg.keyRefreshLoop(ctx, verifier)
	go func() {
		<-ctx.Done()
		_ = httpSrv.Close()
	}()

	if err := httpSrv.ServeTLS(ln, "", ""); err != nil && err != http.ErrServerClosed {
		return fmt.Errorf("a2a: serve: %w", err)
	}
	return nil
}

func (cfg RunnerConfig) keyRefreshLoop(ctx context.Context, verifier *Verifier) {
	ticker := time.NewTicker(cfg.RefreshInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if _, err := RefreshKeys(verifier, cfg.Fetcher); err != nil {
				reportErr(cfg.OnError, fmt.Errorf("a2a: refresh capability keys: %w", err))
			}
		}
	}
}

func loadCAPool(path string) (*x509.CertPool, error) {
	pemBytes, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(pemBytes) {
		return nil, fmt.Errorf("no certificates in %s", path)
	}
	return pool, nil
}

func reportErr(onError func(error), err error) {
	if onError != nil {
		onError(err)
	}
}
