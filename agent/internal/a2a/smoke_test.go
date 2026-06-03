package a2a

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
)

// TestLiveTokenInterop is a cross-language LIVE smoke: it round-trips a REAL
// capability token minted by the platform's Ruby
// System::PeerCapabilityTokenSigner (Ed25519 over a Vault-held key) through the
// Go A2A MCP server over mTLS — proving the Ruby-mint -> Go-verify -> dispatch
// path with genuine platform crypto material.
//
// Skipped unless A2A_SMOKE_TOKEN points to a fixture written by the rails-runner
// harness, shaped:
//
//	{"envelope","signature","public_key","handle","sub","aud","skill"}
//
// Run:
//
//	rails runner <mint-and-write-fixture.rb>   # writes /tmp/a2a_smoke_token.json
//	A2A_SMOKE_TOKEN=/tmp/a2a_smoke_token.json go test -run TestLiveTokenInterop ./internal/a2a/
//
// The mTLS certs here are generated locally with CN = the token's sub/aud; the
// node-cert ExtKeyUsage widening (serverAuth) is a separate prod concern. This
// smoke proves the TOKEN + transport path, not cert provenance.
func TestLiveTokenInterop(t *testing.T) {
	path := os.Getenv("A2A_SMOKE_TOKEN")
	if path == "" {
		t.Skip("set A2A_SMOKE_TOKEN to a platform-minted token fixture to run the live interop smoke")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var fix struct {
		Envelope  string `json:"envelope"`
		Signature string `json:"signature"`
		PublicKey string `json:"public_key"`
		Handle    string `json:"handle"`
		Sub       string `json:"sub"`
		Aud       string `json:"aud"`
		Skill     string `json:"skill"`
	}
	if err := json.Unmarshal(raw, &fix); err != nil {
		t.Fatalf("parse fixture: %v", err)
	}

	// Trust the platform's advertised capability-signing key.
	v := NewVerifier()
	if err := v.TrustKey(fix.Handle, fix.PublicKey); err != nil {
		t.Fatalf("trust key: %v", err)
	}

	// mTLS certs with CN matching the token's sub (caller) / aud (this server).
	ca := newTestCA(t)
	serverCert := ca.leaf(t, fix.Aud, true)
	clientCert := ca.leaf(t, fix.Sub, false)

	reg := NewRegistry()
	reg.RegisterPing()
	srv := NewServer(fix.Aud, v, reg) // real clock — token must be unexpired

	ts := httptest.NewUnstartedServer(srv.Handler())
	ts.TLS = ServerTLSConfig(serverCert, ca.pool)
	ts.StartTLS()
	defer ts.Close()

	cli := NewClient(&http.Client{Transport: &http.Transport{TLSClientConfig: ClientTLSConfig(clientCert, ca.pool)}})
	tok := &Token{Envelope: fix.Envelope, Signature: fix.Signature}

	res, err := cli.CallSkill(ts.URL, tok, fix.Skill, map[string]any{"smoke": true})
	if err != nil {
		t.Fatalf("ruby-minted token round-trip failed: %v", err)
	}
	var out map[string]any
	if err := json.Unmarshal(res, &out); err != nil {
		t.Fatal(err)
	}
	if out["pong"] != true {
		t.Fatalf("expected pong:true from the ruby-token round-trip, got %v", out)
	}
	t.Logf("cross-language A2A OK: platform-minted token (handle=%s, sub=%s, aud=%s) verified + %q dispatched over mTLS",
		fix.Handle, fix.Sub, fix.Aud, fix.Skill)
}
