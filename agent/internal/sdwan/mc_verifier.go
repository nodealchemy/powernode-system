// mc_verifier.go — agent-side verification + cache for membership
// credentials issued by the platform controller.
//
// The platform embeds a per-peer membership credential (MC) envelope in
// the per-tick config push (`/node_api/config/sdwan`). The MC is a
// JWT-shaped JSON document signed with the constellation's Ed25519
// signing key. On every reconcile the agent:
//
//  1. Decodes the envelope + signature.
//  2. Verifies the Ed25519 signature against the constellation public
//     key the agent has cached for that handle.
//  3. Checks the time window (`nbf <= now < exp`).
//  4. Checks the revision is monotonic against the cached entry.
//  5. Cache the validated MC keyed by (peer, network).
//
// The Manager reconcile loop calls `Validate` for each peer's MC. A
// failed validation marks that (peer, network) tuple as ineligible for
// forwarding — the manager refuses to bring up / keep up the WG tunnel
// until a fresh, valid MC arrives.
//
// Refresh-before-expiry: callers periodically call `RefreshDueWithin`
// to learn which cached MCs are inside the refresh window — they
// trigger an early heartbeat to fetch a fresh config.
//
// Phase N0 of the in-house encrypted mesh overlay roadmap.

package sdwan

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

// MCEnvelope is the parsed content of the signed JSON body. Mirrors the
// `Sdwan::MembershipCredentialSigner#render_envelope` output.
type MCEnvelope struct {
	Issuer               string                   `json:"iss"`
	Subject              string                   `json:"sub"`
	Audience             string                   `json:"aud"`
	IssuedAt             int64                    `json:"iat"`
	NotBefore            int64                    `json:"nbf"`
	Expires              int64                    `json:"exp"`
	Revision             int64                    `json:"rev"`
	WireguardPubKey      string                   `json:"wg_pubkey"`
	AddressV6            string                   `json:"addr_v6"`
	ManagedRoutes        []map[string]interface{} `json:"managed_routes"`
	Tags                 []map[string]interface{} `json:"tags"`
	Capabilities         []string                 `json:"capabilities"`
	Endpoints            []map[string]interface{} `json:"endpoints"`
}

// MCWire — the over-the-wire shape served by the platform alongside the
// rest of the per-network config. Mirrors
// `Sdwan::MembershipCredential#to_wire`.
type MCWire struct {
	Envelope            string `json:"envelope"`              // canonical JSON of MCEnvelope
	Signature           string `json:"signature"`             // base64 Ed25519 signature
	ConstellationHandle string `json:"constellation_handle"`  // signing key locator
	Revision            int64  `json:"revision"`
	NotBefore           string `json:"not_before"`            // RFC3339
	NotAfter            string `json:"not_after"`             // RFC3339
	RefreshAfter        string `json:"refresh_after"`         // RFC3339
}

// CachedMC is what the verifier stores per (peer, network) after a
// successful validation. The Manager checks these to decide whether to
// keep a tunnel up.
type CachedMC struct {
	PeerID              string
	NetworkID           string
	Revision            int64
	Envelope            MCEnvelope
	NotBefore           time.Time
	NotAfter            time.Time
	RefreshAfter        time.Time
	ConstellationHandle string
	ValidatedAt         time.Time
}

// Usable returns true if the cached MC is currently within its time
// window. The Manager forwarding gate uses this on every tick.
func (c *CachedMC) Usable(now time.Time) bool {
	return !now.Before(c.NotBefore) && now.Before(c.NotAfter)
}

// RefreshDue returns true once `now` has crossed `RefreshAfter`. The
// reconcile loop uses this to ask the platform for a fresh MC.
func (c *CachedMC) RefreshDue(now time.Time) bool {
	return !now.Before(c.RefreshAfter) && now.Before(c.NotAfter)
}

// MCVerifier is the public surface. Safe for concurrent use.
type MCVerifier struct {
	mu        sync.RWMutex
	cache     map[string]*CachedMC // key = "<peer>|<network>"
	pubKeys   map[string]ed25519.PublicKey
	clockSkew time.Duration // tolerance for clock drift between platform and node
}

// NewMCVerifier — defaults: 60s clock skew tolerance.
func NewMCVerifier() *MCVerifier {
	return &MCVerifier{
		cache:     make(map[string]*CachedMC),
		pubKeys:   make(map[string]ed25519.PublicKey),
		clockSkew: 60 * time.Second,
	}
}

// TrustConstellation registers a public key the verifier will accept
// for envelopes whose `constellation_handle` matches the given handle.
// Idempotent.
func (v *MCVerifier) TrustConstellation(handle string, pubKeyB64 string) error {
	pubRaw, err := base64.StdEncoding.DecodeString(pubKeyB64)
	if err != nil {
		return fmt.Errorf("decode constellation public key: %w", err)
	}
	if len(pubRaw) != ed25519.PublicKeySize {
		return fmt.Errorf("constellation public key wrong length: got %d want %d", len(pubRaw), ed25519.PublicKeySize)
	}
	v.mu.Lock()
	v.pubKeys[handle] = ed25519.PublicKey(pubRaw)
	v.mu.Unlock()
	return nil
}

// Validate checks the wire-form MC and, on success, caches the result
// and returns a pointer to the cached entry. The Manager calls this
// every reconcile; an error means the peer should be considered
// non-member for this tick.
func (v *MCVerifier) Validate(peerID, networkID string, wire *MCWire, now time.Time) (*CachedMC, error) {
	if wire == nil {
		return nil, errors.New("nil MC wire")
	}
	if strings.TrimSpace(wire.Envelope) == "" {
		return nil, errors.New("empty MC envelope")
	}
	if strings.TrimSpace(wire.Signature) == "" {
		return nil, errors.New("empty MC signature")
	}

	v.mu.RLock()
	pub, ok := v.pubKeys[wire.ConstellationHandle]
	v.mu.RUnlock()
	if !ok {
		return nil, fmt.Errorf("untrusted constellation %q", wire.ConstellationHandle)
	}

	sig, err := base64.StdEncoding.DecodeString(wire.Signature)
	if err != nil {
		return nil, fmt.Errorf("decode signature: %w", err)
	}
	if len(sig) != ed25519.SignatureSize {
		return nil, fmt.Errorf("signature wrong length: got %d want %d", len(sig), ed25519.SignatureSize)
	}

	if !ed25519.Verify(pub, []byte(wire.Envelope), sig) {
		return nil, errors.New("Ed25519 signature mismatch")
	}

	var env MCEnvelope
	if err := json.Unmarshal([]byte(wire.Envelope), &env); err != nil {
		return nil, fmt.Errorf("parse envelope: %w", err)
	}

	notBefore := time.Unix(env.NotBefore, 0)
	notAfter := time.Unix(env.Expires, 0)
	// Apply clock skew tolerance only to the lower bound — being
	// permissive on the upper bound would let the agent forward past
	// the controller's intended expiry.
	if now.Add(v.clockSkew).Before(notBefore) {
		return nil, fmt.Errorf("MC not yet valid (nbf=%s, now=%s)", notBefore.Format(time.RFC3339), now.Format(time.RFC3339))
	}
	if !now.Before(notAfter) {
		return nil, fmt.Errorf("MC expired (exp=%s, now=%s)", notAfter.Format(time.RFC3339), now.Format(time.RFC3339))
	}

	if env.Revision <= 0 {
		return nil, errors.New("MC revision must be positive")
	}

	// Monotonic revision check — drops a stale envelope that an
	// attacker might replay after a controller has already issued a
	// newer one.
	cacheKey := peerID + "|" + networkID
	v.mu.Lock()
	if existing, ok := v.cache[cacheKey]; ok && existing.Revision > env.Revision {
		v.mu.Unlock()
		return nil, fmt.Errorf("MC revision regression: cached=%d, received=%d", existing.Revision, env.Revision)
	}

	refreshAfter := parseRFC3339OrFallback(wire.RefreshAfter, notBefore.Add(notAfter.Sub(notBefore)/2))
	cached := &CachedMC{
		PeerID:              peerID,
		NetworkID:           networkID,
		Revision:            env.Revision,
		Envelope:            env,
		NotBefore:           notBefore,
		NotAfter:            notAfter,
		RefreshAfter:        refreshAfter,
		ConstellationHandle: wire.ConstellationHandle,
		ValidatedAt:         now,
	}
	v.cache[cacheKey] = cached
	v.mu.Unlock()

	return cached, nil
}

// Lookup returns the cached MC for (peer, network), or nil if none.
func (v *MCVerifier) Lookup(peerID, networkID string) *CachedMC {
	v.mu.RLock()
	defer v.mu.RUnlock()
	return v.cache[peerID+"|"+networkID]
}

// Forget removes a cached MC. Called when a peer leaves or a network is
// torn down.
func (v *MCVerifier) Forget(peerID, networkID string) {
	v.mu.Lock()
	delete(v.cache, peerID+"|"+networkID)
	v.mu.Unlock()
}

// IsForwardingAllowed — the Manager forwarding gate's authoritative
// answer. Returns true only when (a) there is a cached MC and (b) the
// MC is currently usable. Missing MC → false (membership unproven).
func (v *MCVerifier) IsForwardingAllowed(peerID, networkID string, now time.Time) bool {
	c := v.Lookup(peerID, networkID)
	if c == nil {
		return false
	}
	return c.Usable(now)
}

// RefreshDueWithin returns the cache keys ((peer, network) pairs) whose
// refresh_after has been crossed and which should trigger an early
// config fetch. The reconcile loop reports these to the platform via
// the next heartbeat so the controller knows to re-issue.
func (v *MCVerifier) RefreshDueWithin(now time.Time) []string {
	v.mu.RLock()
	defer v.mu.RUnlock()
	out := make([]string, 0)
	for k, c := range v.cache {
		if c.RefreshDue(now) {
			out = append(out, k)
		}
	}
	return out
}

// SnapshotCacheSize is exported for instrumentation/heartbeat blocks.
func (v *MCVerifier) SnapshotCacheSize() int {
	v.mu.RLock()
	defer v.mu.RUnlock()
	return len(v.cache)
}

func parseRFC3339OrFallback(s string, fallback time.Time) time.Time {
	if t, err := time.Parse(time.RFC3339, s); err == nil {
		return t
	}
	return fallback
}
