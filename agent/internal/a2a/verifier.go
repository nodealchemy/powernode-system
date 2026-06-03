// verifier.go — agent-side verification of peer capability tokens.
//
// A capability token is an Ed25519-signed canonical-JSON envelope minted by the
// platform's System::PeerCapabilityTokenSigner. It proves the bearer (sub) may
// invoke a skill on a target instance (aud). The agent verifies it OFFLINE:
//
//  1. Parse the (untrusted) envelope to learn its `iss` (signing-key handle).
//  2. Look up the trusted Ed25519 public key registered for that handle
//     (advertised by the platform via node_api/a2a/capability_keys).
//  3. Verify the Ed25519 signature over the exact envelope bytes.
//  4. Check the time window (nbf <= now < exp, clock-skew tolerant on nbf).
//  5. Check aud == self instance id and skill == the tool being invoked.
//
// Mirrors internal/sdwan/mc_verifier.go (same Ed25519 + trusted-key-by-handle
// + clock-skew shape).

package a2a

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"
)

// Claims is the parsed content of a capability-token envelope. Mirrors
// System::PeerCapabilityTokenSigner's claim hash.
type Claims struct {
	Version   int    `json:"v"`
	Issuer    string `json:"iss"` // signing-key handle (key locator)
	Account   string `json:"account"`
	Subject   string `json:"sub"`   // caller instance id (grantee)
	Audience  string `json:"aud"`   // target instance id (this node)
	Skill     string `json:"skill"` // the single skill this token authorizes
	IssuedAt  int64  `json:"iat"`
	NotBefore int64  `json:"nbf"`
	Expires   int64  `json:"exp"`
	JTI       string `json:"jti"`
}

// Token is the over-the-wire shape: the canonical JSON envelope + its base64
// Ed25519 signature. Carried in the A2A MCP call's Authorization material.
type Token struct {
	Envelope  string `json:"envelope"`  // canonical JSON of Claims (signed bytes)
	Signature string `json:"signature"` // base64 Ed25519 signature over Envelope
}

// Verifier holds the trusted capability-signing public keys (by handle) and
// verifies tokens offline. Safe for concurrent use.
type Verifier struct {
	mu        sync.RWMutex
	pubKeys   map[string]ed25519.PublicKey
	clockSkew time.Duration
}

// NewVerifier — defaults: 60s clock-skew tolerance (matches mc_verifier).
func NewVerifier() *Verifier {
	return &Verifier{
		pubKeys:   make(map[string]ed25519.PublicKey),
		clockSkew: 60 * time.Second,
	}
}

// TrustKey registers a public key the verifier accepts for tokens whose `iss`
// (handle) matches. Idempotent. Mirrors MCVerifier.TrustConstellation.
func (v *Verifier) TrustKey(handle, pubKeyB64 string) error {
	pubRaw, err := base64.StdEncoding.DecodeString(pubKeyB64)
	if err != nil {
		return fmt.Errorf("decode capability public key: %w", err)
	}
	if len(pubRaw) != ed25519.PublicKeySize {
		return fmt.Errorf("capability public key wrong length: got %d want %d", len(pubRaw), ed25519.PublicKeySize)
	}
	v.mu.Lock()
	v.pubKeys[handle] = ed25519.PublicKey(pubRaw)
	v.mu.Unlock()
	return nil
}

// TrustedHandles returns the handles currently trusted (for instrumentation).
func (v *Verifier) TrustedHandles() []string {
	v.mu.RLock()
	defer v.mu.RUnlock()
	out := make([]string, 0, len(v.pubKeys))
	for h := range v.pubKeys {
		out = append(out, h)
	}
	return out
}

// Verify checks a capability token for an inbound call: signature, time window,
// audience == selfInstanceID, and skill == the tool being invoked. callerCN is
// the verified mTLS client-cert CN — it MUST equal the token's `sub` (the
// connector is the grantee, not a token-relayer). Returns the validated claims.
func (v *Verifier) Verify(tok *Token, selfInstanceID, callerCN, skill string, now time.Time) (*Claims, error) {
	if tok == nil {
		return nil, errors.New("nil capability token")
	}
	if strings.TrimSpace(tok.Envelope) == "" {
		return nil, errors.New("empty token envelope")
	}
	if strings.TrimSpace(tok.Signature) == "" {
		return nil, errors.New("empty token signature")
	}

	// Parse the (still-untrusted) envelope to learn which key signed it.
	var claims Claims
	if err := json.Unmarshal([]byte(tok.Envelope), &claims); err != nil {
		return nil, fmt.Errorf("parse token envelope: %w", err)
	}

	v.mu.RLock()
	pub, ok := v.pubKeys[claims.Issuer]
	v.mu.RUnlock()
	if !ok {
		return nil, fmt.Errorf("untrusted capability signer %q", claims.Issuer)
	}

	sig, err := base64.StdEncoding.DecodeString(tok.Signature)
	if err != nil {
		return nil, fmt.Errorf("decode signature: %w", err)
	}
	if len(sig) != ed25519.SignatureSize {
		return nil, fmt.Errorf("signature wrong length: got %d want %d", len(sig), ed25519.SignatureSize)
	}
	if !ed25519.Verify(pub, []byte(tok.Envelope), sig) {
		return nil, errors.New("Ed25519 signature mismatch")
	}

	// Signature is valid — claims are now trusted. Enforce the capability.
	notBefore := time.Unix(claims.NotBefore, 0)
	notAfter := time.Unix(claims.Expires, 0)
	if claims.NotBefore != 0 && now.Add(v.clockSkew).Before(notBefore) {
		return nil, fmt.Errorf("token not yet valid (nbf=%s, now=%s)", notBefore.Format(time.RFC3339), now.Format(time.RFC3339))
	}
	if claims.Expires != 0 && !now.Before(notAfter) {
		return nil, fmt.Errorf("token expired (exp=%s, now=%s)", notAfter.Format(time.RFC3339), now.Format(time.RFC3339))
	}
	if selfInstanceID != "" && claims.Audience != selfInstanceID {
		return nil, fmt.Errorf("audience mismatch: token aud=%q self=%q", claims.Audience, selfInstanceID)
	}
	if callerCN != "" && claims.Subject != callerCN {
		return nil, fmt.Errorf("subject mismatch: token sub=%q mTLS CN=%q", claims.Subject, callerCN)
	}
	if skill != "" && claims.Skill != skill {
		return nil, fmt.Errorf("skill mismatch: token skill=%q requested=%q", claims.Skill, skill)
	}

	return &claims, nil
}
