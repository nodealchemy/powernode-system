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
// meant. Names are normalized (cap_chown == CAP_CHOWN == chown) before the
// subset check; an unknown name in either list is an error.
//
// The result is normalized, de-duplicated and sorted; it is never nil.
func ResolveServiceCapabilities(ceiling []string, declared bool, own []string) ([]string, error) {
	ceil, err := canonicalCapSet(ceiling)
	if err != nil {
		return nil, fmt.Errorf("module capability ceiling: %w", err)
	}
	if !declared {
		return sortedKeys(ceil), nil
	}
	mine, err := canonicalCapSet(own)
	if err != nil {
		return nil, fmt.Errorf("service capabilities: %w", err)
	}
	var outside []string
	for name := range mine {
		if _, ok := ceil[name]; !ok {
			outside = append(outside, name)
		}
	}
	if len(outside) > 0 {
		sort.Strings(outside)
		return nil, fmt.Errorf("service capabilities %s are outside the module's security.capabilities ceiling %v",
			strings.Join(outside, ", "), sortedKeys(ceil))
	}
	return sortedKeys(mine), nil
}

func canonicalCapSet(names []string) (map[string]struct{}, error) {
	out := make(map[string]struct{}, len(names))
	for _, n := range names {
		canon, ok := normalizeCapName(n)
		if !ok {
			return nil, fmt.Errorf("unknown capability %q", n)
		}
		out[canon] = struct{}{}
	}
	return out, nil
}

func sortedKeys(set map[string]struct{}) []string {
	out := make([]string, 0, len(set))
	for k := range set {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
