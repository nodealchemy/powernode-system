package security

import (
	"fmt"
	"sort"
	"strings"
)

// UnitCapabilities is one unit's RESOLVED capability set: what the drop-in
// writers for that unit are handed (IMP-caef5c00d63f).
type UnitCapabilities struct {
	Unit  string
	Allow []string
}

// ResolveServiceCapabilities is the per-service capability rule, as a pure
// function so both attach paths and the re-attach stamp apply it identically
// (IMP-caef5c00d63f):
//
//   - the module's security.capabilities (ceiling) bounds every unit;
//   - declared == false (the service has no capabilities key) inherits the
//     whole ceiling — today's module-wide behaviour, unchanged;
//   - declared == true gets exactly `own`, which must be a subset of the
//     ceiling; an empty `own` is ZERO capabilities, not "inherit".
//
// `declared` is passed explicitly and is never inferred from len(own): the
// distinction between an absent key and an explicit [] is the whole point.
//
// A declared name outside the ceiling is an error, not silently dropped: a
// manifest asking for more than its module grants is misconfigured, and the
// callers refuse the module rather than guess which of the two the author
// meant. Names are normalized (cap_chown == CAP_CHOWN == chown — a bare name
// still NORMALIZES via normalizeCapName's own CAP_ prefixing, it is not
// touched by the dropping below, which only ever applies to a name
// normalizeCapName does not recognize under ANY spelling) before the subset
// check.
//
// L4 (review round 7, MEDIUM): a name this agent binary does NOT recognize
// under any spelling (normalizeCapName returns ok=false) is DROPPED, not
// refused — the same narrower-never-wider response Policy.DropUnknownCapabilities
// already applies to the MODULE-WIDE ceiling (K5b, round 6) for exactly the
// same version-skew reason, now extended to the per-service list K5b's own
// scope did not cover. `dropped` names both the ceiling's and `own`'s
// unrecognized entries (deduplication is the caller's concern, same as
// Policy.DropUnknownCapabilities's own contract) so a caller can warn — this
// function stays pure and never itself emits a diagnostic. Distinct from
// "outside the ceiling" below: a name recognized by this agent but not
// granted by the module's own declared ceiling is a REAL authoring mistake,
// not a version-skew name, and stays a hard refusal.
//
// The result is normalized, de-duplicated and sorted; it is never nil on
// success.
func ResolveServiceCapabilities(ceiling []string, declared bool, own []string) (allow []string, dropped []string, err error) {
	ceil, ceilDropped := canonicalCapSet(ceiling)
	dropped = append(dropped, ceilDropped...)
	if !declared {
		return sortedKeys(ceil), dropped, nil
	}
	mine, ownDropped := canonicalCapSet(own)
	dropped = append(dropped, ownDropped...)
	var outside []string
	for name := range mine {
		if _, ok := ceil[name]; !ok {
			outside = append(outside, name)
		}
	}
	if len(outside) > 0 {
		sort.Strings(outside)
		return nil, dropped, fmt.Errorf("service capabilities %s are outside the module's security.capabilities ceiling %v",
			strings.Join(outside, ", "), sortedKeys(ceil))
	}
	return sortedKeys(mine), dropped, nil
}

// canonicalCapSet normalizes names, DROPPING (never erroring on) any name
// normalizeCapName does not recognize under any spelling — see
// ResolveServiceCapabilities's own doc for why dropping, not refusing, is
// correct here (L4, review round 7).
func canonicalCapSet(names []string) (set map[string]struct{}, dropped []string) {
	set = make(map[string]struct{}, len(names))
	for _, n := range names {
		canon, ok := normalizeCapName(n)
		if !ok {
			dropped = append(dropped, n)
			continue
		}
		set[canon] = struct{}{}
	}
	return set, dropped
}

func sortedKeys(set map[string]struct{}) []string {
	out := make([]string, 0, len(set))
	for k := range set {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
