package security

import "testing"

// K5b (review round 6): "both delivery orders have a skew window" between an
// agent binary's KnownCapabilities and a manifest authored against a
// different agent version. J5 already documented (and left unfixed, by
// design — see the qga manifest's own comment) the NEWER-agent/OLDER-
// manifest direction: a manifest missing a capability the newer agent added
// still resolves to a STRICT SUBSET of KnownCapabilities, which
// IsFullCapabilitySet correctly (and deliberately) refuses to treat as full.
// This file pins BOTH directions so a future change to either function
// cannot silently reintroduce or over-correct either one.

// Direction 1 (K5b's actual fix): an OLDER agent receiving a manifest
// declaring a capability from a NEWER agent version. DropUnknownCapabilities
// strips the name it doesn't recognize; what remains collapses to EXACTLY
// this agent's own KnownCapabilities, which IsFullCapabilitySet's existing
// exact-match logic already treats as full — no change to that function was
// needed.
func TestIsFullCapabilitySet_SupersetAfterDroppingUnknownCollapsesToFull(t *testing.T) {
	allow := make([]string, 0, len(KnownCapabilities)+1)
	for c := range KnownCapabilities {
		allow = append(allow, c)
	}
	allow = append(allow, "CAP_FUTURE_THING_A_NEWER_AGENT_ADDED")

	p := &Policy{Capabilities: allow}
	dropped := p.DropUnknownCapabilities()
	if len(dropped) != 1 || dropped[0] != "CAP_FUTURE_THING_A_NEWER_AGENT_ADDED" {
		t.Fatalf("expected exactly the unrecognized name dropped, got %v", dropped)
	}
	if !IsFullCapabilitySet(p.Capabilities) {
		t.Errorf("K5b REGRESSION: a superset that collapses to EXACTLY KnownCapabilities after dropping the unrecognized extra must read as full, got %v", p.Capabilities)
	}
}

// Direction 2 (J5's already-documented, deliberately UNFIXED direction): a
// NEWER agent receiving an OLDER manifest that is missing a capability this
// agent added. That declared set is a STRICT SUBSET of KnownCapabilities —
// DropUnknownCapabilities has nothing to drop (every declared name IS
// known), and IsFullCapabilitySet must still refuse it: loosening exactness
// for a subset would let ANY narrower ceiling claim full-set exemption,
// exactly the false-exemption risk IsFullCapabilitySet's own doc comment
// warns against.
func TestIsFullCapabilitySet_SubsetMissingAKnownCapabilityStaysNotFull(t *testing.T) {
	allow := make([]string, 0, len(KnownCapabilities)-1)
	skipped := false
	for c := range KnownCapabilities {
		if !skipped {
			skipped = true
			continue // simulate an older manifest authored before this cap existed
		}
		allow = append(allow, c)
	}

	p := &Policy{Capabilities: allow}
	dropped := p.DropUnknownCapabilities()
	if dropped != nil {
		t.Fatalf("every declared name is a KNOWN capability; expected nothing dropped, got %v", dropped)
	}
	if IsFullCapabilitySet(p.Capabilities) {
		t.Errorf("K5b: a strict subset missing one known capability must NOT read as full (this direction stays refusable by design), got %v", p.Capabilities)
	}
}
