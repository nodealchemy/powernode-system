// mc_verifier_test.go — table-driven Ed25519 verification + cache
// behavior. Phase N0 of the in-house encrypted mesh overlay roadmap.

package sdwan

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

// helper: build a signing pair, register it under a handle, and return
// (verifier, privateKey, handle).
func newTestVerifier(t *testing.T, handle string) (*MCVerifier, ed25519.PrivateKey) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("ed25519.GenerateKey: %v", err)
	}
	v := NewMCVerifier()
	if err := v.TrustConstellation(handle, base64.StdEncoding.EncodeToString(pub)); err != nil {
		t.Fatalf("TrustConstellation: %v", err)
	}
	return v, priv
}

// helper: build + sign an envelope returning a ready-to-validate
// MCWire.
func buildSignedWire(t *testing.T, priv ed25519.PrivateKey, handle string, env MCEnvelope, refreshAfter time.Time, notAfterOverride *time.Time) *MCWire {
	t.Helper()
	body, err := json.Marshal(env)
	if err != nil {
		t.Fatalf("marshal envelope: %v", err)
	}
	sig := ed25519.Sign(priv, body)

	notAfter := time.Unix(env.Expires, 0)
	if notAfterOverride != nil {
		notAfter = *notAfterOverride
	}

	return &MCWire{
		Envelope:            string(body),
		Signature:           base64.StdEncoding.EncodeToString(sig),
		ConstellationHandle: handle,
		Revision:            env.Revision,
		NotBefore:           time.Unix(env.NotBefore, 0).UTC().Format(time.RFC3339),
		NotAfter:            notAfter.UTC().Format(time.RFC3339),
		RefreshAfter:        refreshAfter.UTC().Format(time.RFC3339),
	}
}

func TestMCVerifier_HappyPath(t *testing.T) {
	const handle = "acct-test"
	v, priv := newTestVerifier(t, handle)

	now := time.Unix(1_700_000_000, 0)
	env := MCEnvelope{
		Issuer:          handle,
		Subject:         "peerhandle-001",
		Audience:        "net-abcd1234",
		IssuedAt:        now.Unix(),
		NotBefore:       now.Unix(),
		Expires:         now.Add(1 * time.Hour).Unix(),
		Revision:        1,
		WireguardPubKey: "fakebase64",
		AddressV6:       "fd00::1",
	}
	wire := buildSignedWire(t, priv, handle, env, now.Add(30*time.Minute), nil)

	cached, err := v.Validate("peer-uuid-1", "net-uuid-1", wire, now)
	if err != nil {
		t.Fatalf("Validate happy path returned error: %v", err)
	}
	if cached == nil {
		t.Fatal("Validate returned nil cache entry")
	}
	if cached.Revision != 1 {
		t.Errorf("Revision: got %d, want 1", cached.Revision)
	}
	if !cached.Usable(now) {
		t.Error("MC should be usable at the time it was just validated")
	}
	if v.SnapshotCacheSize() != 1 {
		t.Errorf("cache size: got %d, want 1", v.SnapshotCacheSize())
	}
	if !v.IsForwardingAllowed("peer-uuid-1", "net-uuid-1", now) {
		t.Error("IsForwardingAllowed should be true for a valid cached MC")
	}
}

func TestMCVerifier_RejectsBadSignature(t *testing.T) {
	const handle = "acct-test"
	v, priv := newTestVerifier(t, handle)

	now := time.Unix(1_700_000_000, 0)
	env := MCEnvelope{
		Issuer:    handle,
		NotBefore: now.Unix(),
		Expires:   now.Add(1 * time.Hour).Unix(),
		Revision:  1,
	}
	wire := buildSignedWire(t, priv, handle, env, now.Add(30*time.Minute), nil)

	// Tamper the body — signature no longer matches.
	wire.Envelope = strings.Replace(wire.Envelope, `"rev":1`, `"rev":99`, 1)

	_, err := v.Validate("p", "n", wire, now)
	if err == nil {
		t.Fatal("expected signature mismatch error")
	}
	if !strings.Contains(err.Error(), "signature mismatch") {
		t.Errorf("unexpected error: %v", err)
	}
}

func TestMCVerifier_RejectsExpired(t *testing.T) {
	const handle = "acct-test"
	v, priv := newTestVerifier(t, handle)

	now := time.Unix(1_700_000_000, 0)
	env := MCEnvelope{
		Issuer:    handle,
		NotBefore: now.Add(-2 * time.Hour).Unix(),
		Expires:   now.Add(-1 * time.Hour).Unix(),
		Revision:  1,
	}
	wire := buildSignedWire(t, priv, handle, env, now.Add(-90*time.Minute), nil)

	_, err := v.Validate("p", "n", wire, now)
	if err == nil || !strings.Contains(err.Error(), "expired") {
		t.Fatalf("expected expired error, got %v", err)
	}
}

func TestMCVerifier_RejectsNotYetValid(t *testing.T) {
	const handle = "acct-test"
	v, priv := newTestVerifier(t, handle)

	now := time.Unix(1_700_000_000, 0)
	env := MCEnvelope{
		Issuer:    handle,
		// nbf is well past the clock skew tolerance.
		NotBefore: now.Add(10 * time.Minute).Unix(),
		Expires:   now.Add(1 * time.Hour).Unix(),
		Revision:  1,
	}
	wire := buildSignedWire(t, priv, handle, env, now.Add(30*time.Minute), nil)

	_, err := v.Validate("p", "n", wire, now)
	if err == nil || !strings.Contains(err.Error(), "not yet valid") {
		t.Fatalf("expected not-yet-valid error, got %v", err)
	}
}

func TestMCVerifier_AllowsClockSkewOnNbf(t *testing.T) {
	const handle = "acct-test"
	v, priv := newTestVerifier(t, handle)

	now := time.Unix(1_700_000_000, 0)
	env := MCEnvelope{
		Issuer:    handle,
		// nbf is 30s in the future, well within the 60s tolerance.
		NotBefore: now.Add(30 * time.Second).Unix(),
		Expires:   now.Add(1 * time.Hour).Unix(),
		Revision:  1,
	}
	wire := buildSignedWire(t, priv, handle, env, now.Add(30*time.Minute), nil)

	if _, err := v.Validate("p", "n", wire, now); err != nil {
		t.Fatalf("expected clock-skew tolerance to allow validation, got %v", err)
	}
}

func TestMCVerifier_RejectsUntrustedConstellation(t *testing.T) {
	v := NewMCVerifier()
	_, priv, _ := ed25519.GenerateKey(rand.Reader)

	now := time.Unix(1_700_000_000, 0)
	env := MCEnvelope{
		Issuer:    "stranger",
		NotBefore: now.Unix(),
		Expires:   now.Add(1 * time.Hour).Unix(),
		Revision:  1,
	}
	wire := buildSignedWire(t, priv, "stranger", env, now.Add(30*time.Minute), nil)

	_, err := v.Validate("p", "n", wire, now)
	if err == nil || !strings.Contains(err.Error(), "untrusted") {
		t.Fatalf("expected untrusted constellation error, got %v", err)
	}
}

func TestMCVerifier_RejectsRevisionRegression(t *testing.T) {
	const handle = "acct-test"
	v, priv := newTestVerifier(t, handle)

	now := time.Unix(1_700_000_000, 0)
	envHigh := MCEnvelope{
		Issuer:    handle,
		NotBefore: now.Unix(),
		Expires:   now.Add(1 * time.Hour).Unix(),
		Revision:  5,
	}
	wireHigh := buildSignedWire(t, priv, handle, envHigh, now.Add(30*time.Minute), nil)
	if _, err := v.Validate("peer", "net", wireHigh, now); err != nil {
		t.Fatalf("first Validate failed: %v", err)
	}

	envLow := envHigh
	envLow.Revision = 3
	wireLow := buildSignedWire(t, priv, handle, envLow, now.Add(30*time.Minute), nil)

	_, err := v.Validate("peer", "net", wireLow, now)
	if err == nil || !strings.Contains(err.Error(), "revision regression") {
		t.Fatalf("expected revision regression error, got %v", err)
	}

	// Re-issuing the same revision is allowed (idempotent refresh).
	if _, err := v.Validate("peer", "net", wireHigh, now); err != nil {
		t.Fatalf("re-validate of same revision failed: %v", err)
	}
}

func TestMCVerifier_RefreshDueWithin(t *testing.T) {
	const handle = "acct-test"
	v, priv := newTestVerifier(t, handle)

	now := time.Unix(1_700_000_000, 0)
	envFresh := MCEnvelope{
		Issuer:    handle,
		NotBefore: now.Unix(),
		Expires:   now.Add(1 * time.Hour).Unix(),
		Revision:  1,
	}
	wireFresh := buildSignedWire(t, priv, handle, envFresh, now.Add(30*time.Minute), nil)
	if _, err := v.Validate("peer-fresh", "net-1", wireFresh, now); err != nil {
		t.Fatalf("validate fresh: %v", err)
	}

	envStale := envFresh
	envStale.Revision = 2
	wireStale := buildSignedWire(t, priv, handle, envStale, now.Add(-1*time.Minute), nil)
	if _, err := v.Validate("peer-stale", "net-1", wireStale, now); err != nil {
		t.Fatalf("validate stale: %v", err)
	}

	due := v.RefreshDueWithin(now)
	if len(due) != 1 || due[0] != "peer-stale|net-1" {
		t.Errorf("RefreshDueWithin: got %v, want [peer-stale|net-1]", due)
	}
}

func TestMCVerifier_IsForwardingAllowed_MissingMC(t *testing.T) {
	v := NewMCVerifier()
	if v.IsForwardingAllowed("p", "n", time.Now()) {
		t.Error("expected forwarding to be denied when no MC is cached")
	}
}

func TestMCVerifier_Forget(t *testing.T) {
	const handle = "acct-test"
	v, priv := newTestVerifier(t, handle)

	now := time.Unix(1_700_000_000, 0)
	env := MCEnvelope{
		Issuer:    handle,
		NotBefore: now.Unix(),
		Expires:   now.Add(1 * time.Hour).Unix(),
		Revision:  1,
	}
	wire := buildSignedWire(t, priv, handle, env, now.Add(30*time.Minute), nil)
	if _, err := v.Validate("p", "n", wire, now); err != nil {
		t.Fatalf("validate: %v", err)
	}

	v.Forget("p", "n")
	if v.Lookup("p", "n") != nil {
		t.Error("Forget should have removed the cache entry")
	}
}

func TestMCVerifier_RejectsBadSignatureLength(t *testing.T) {
	const handle = "acct-test"
	v, _ := newTestVerifier(t, handle)

	wire := &MCWire{
		Envelope:            `{"rev":1}`,
		Signature:           base64.StdEncoding.EncodeToString([]byte("too-short")),
		ConstellationHandle: handle,
	}
	_, err := v.Validate("p", "n", wire, time.Now())
	if err == nil || !strings.Contains(err.Error(), "wrong length") {
		t.Fatalf("expected wrong-length error, got %v", err)
	}
}

func TestMCVerifier_TrustConstellationRejectsBadKey(t *testing.T) {
	v := NewMCVerifier()
	if err := v.TrustConstellation("h", "not-base64!"); err == nil {
		t.Error("expected error for malformed base64 public key")
	}
	if err := v.TrustConstellation("h", base64.StdEncoding.EncodeToString([]byte("short"))); err == nil {
		t.Error("expected error for wrong-length public key")
	}
}
