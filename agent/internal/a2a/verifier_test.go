package a2a

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"testing"
	"time"
)

func mkClaims(sub, aud, skill string, nbf, exp int64) map[string]any {
	return map[string]any{
		"v": 1, "iss": "a2a-cap-acct-test", "account": "acct-1",
		"sub": sub, "aud": aud, "skill": skill,
		"iat": nbf, "nbf": nbf, "exp": exp, "jti": "jti-1",
	}
}

func signTok(t *testing.T, priv ed25519.PrivateKey, claims map[string]any) *Token {
	t.Helper()
	env, err := json.Marshal(claims)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	sig := ed25519.Sign(priv, env)
	return &Token{Envelope: string(env), Signature: base64.StdEncoding.EncodeToString(sig)}
}

func newTrustedVerifier(t *testing.T, handle string) (*Verifier, ed25519.PrivateKey) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatalf("genkey: %v", err)
	}
	v := NewVerifier()
	if err := v.TrustKey(handle, base64.StdEncoding.EncodeToString(pub)); err != nil {
		t.Fatalf("trust: %v", err)
	}
	return v, priv
}

func TestVerify_Valid(t *testing.T) {
	v, priv := newTrustedVerifier(t, "a2a-cap-acct-test")
	now := time.Unix(1000, 0)
	tok := signTok(t, priv, mkClaims("instA", "instB", "embed-text", 990, 2000))
	claims, err := v.Verify(tok, "instB", "instA", "embed-text", now)
	if err != nil {
		t.Fatalf("expected valid, got %v", err)
	}
	if claims.Subject != "instA" || claims.Audience != "instB" || claims.Skill != "embed-text" {
		t.Fatalf("claims mismatch: %+v", claims)
	}
}

func TestVerify_UntrustedSigner(t *testing.T) {
	v, _ := newTrustedVerifier(t, "trusted-handle") // verifier trusts a DIFFERENT handle
	_, priv2, _ := ed25519.GenerateKey(nil)
	tok := signTok(t, priv2, mkClaims("instA", "instB", "embed-text", 990, 2000)) // iss = a2a-cap-acct-test
	if _, err := v.Verify(tok, "instB", "instA", "embed-text", time.Unix(1000, 0)); err == nil {
		t.Fatal("expected untrusted-signer error")
	}
}

func TestVerify_BadSignature(t *testing.T) {
	v, priv := newTrustedVerifier(t, "a2a-cap-acct-test")
	tok := signTok(t, priv, mkClaims("instA", "instB", "embed-text", 990, 2000))
	// Same iss (key still found) + valid JSON, but different bytes -> sig fails.
	bad, _ := json.Marshal(mkClaims("instA", "instB", "admin-skill", 990, 2000))
	tok.Envelope = string(bad)
	if _, err := v.Verify(tok, "instB", "instA", "admin-skill", time.Unix(1000, 0)); err == nil {
		t.Fatal("expected signature mismatch")
	}
}

func TestVerify_Expired(t *testing.T) {
	v, priv := newTrustedVerifier(t, "a2a-cap-acct-test")
	tok := signTok(t, priv, mkClaims("instA", "instB", "embed-text", 100, 200))
	if _, err := v.Verify(tok, "instB", "instA", "embed-text", time.Unix(1000, 0)); err == nil {
		t.Fatal("expected expired error")
	}
}

func TestVerify_NotYetValid(t *testing.T) {
	v, priv := newTrustedVerifier(t, "a2a-cap-acct-test")
	tok := signTok(t, priv, mkClaims("instA", "instB", "embed-text", 5000, 6000))
	if _, err := v.Verify(tok, "instB", "instA", "embed-text", time.Unix(1000, 0)); err == nil {
		t.Fatal("expected not-yet-valid error")
	}
}

func TestVerify_AudienceMismatch(t *testing.T) {
	v, priv := newTrustedVerifier(t, "a2a-cap-acct-test")
	tok := signTok(t, priv, mkClaims("instA", "instB", "embed-text", 990, 2000))
	if _, err := v.Verify(tok, "instC", "instA", "embed-text", time.Unix(1000, 0)); err == nil {
		t.Fatal("expected audience mismatch (self=instC, aud=instB)")
	}
}

func TestVerify_SubjectMismatch(t *testing.T) {
	v, priv := newTrustedVerifier(t, "a2a-cap-acct-test")
	tok := signTok(t, priv, mkClaims("instA", "instB", "embed-text", 990, 2000))
	// mTLS CN says instX but token sub is instA -> a token-relay attempt.
	if _, err := v.Verify(tok, "instB", "instX", "embed-text", time.Unix(1000, 0)); err == nil {
		t.Fatal("expected subject mismatch")
	}
}

func TestVerify_SkillMismatch(t *testing.T) {
	v, priv := newTrustedVerifier(t, "a2a-cap-acct-test")
	tok := signTok(t, priv, mkClaims("instA", "instB", "embed-text", 990, 2000))
	if _, err := v.Verify(tok, "instB", "instA", "other-skill", time.Unix(1000, 0)); err == nil {
		t.Fatal("expected skill mismatch")
	}
}

// Audit F2-04 — tokens are verified offline, so revocations advertised via
// the capability_keys pull must be enforced here: a revoked sub (peer
// disabled / grants changed) or jti fails even with a valid signature and
// an unexpired window.
func TestVerify_RevokedSub(t *testing.T) {
	v, priv := newTrustedVerifier(t, "a2a-cap-acct-test")
	v.SetRevocations([]string{"instA"}, nil)
	tok := signTok(t, priv, mkClaims("instA", "instB", "embed-text", 990, 2000))
	if _, err := v.Verify(tok, "instB", "instA", "embed-text", time.Unix(1000, 0)); err == nil {
		t.Fatal("expected revoked-sub error")
	}
}

func TestVerify_RevokedJti(t *testing.T) {
	v, priv := newTrustedVerifier(t, "a2a-cap-acct-test")
	v.SetRevocations(nil, []string{"jti-1"})
	tok := signTok(t, priv, mkClaims("instA", "instB", "embed-text", 990, 2000))
	if _, err := v.Verify(tok, "instB", "instA", "embed-text", time.Unix(1000, 0)); err == nil {
		t.Fatal("expected revoked-jti error")
	}
}

func TestVerify_RevocationsReplacedOnRefresh(t *testing.T) {
	v, priv := newTrustedVerifier(t, "a2a-cap-acct-test")
	v.SetRevocations([]string{"instA"}, nil)
	v.SetRevocations(nil, nil) // server stopped advertising it (expired)
	tok := signTok(t, priv, mkClaims("instA", "instB", "embed-text", 990, 2000))
	if _, err := v.Verify(tok, "instB", "instA", "embed-text", time.Unix(1000, 0)); err != nil {
		t.Fatalf("expected valid after revocation expiry, got %v", err)
	}
}
