package security

import (
	"strings"
	"testing"
)

// IMP-caef5c00d63f phase 3 — the pivot-compose fail-closed guard's full-set
// exemption (compose.go) reads on IsFullCapabilitySet being EXACT, not "large
// enough". These pin that directly and cheaply, ahead of the (also present)
// wiring test in runtime/unit_capabilities_test.go.
func TestIsFullCapabilitySet(t *testing.T) {
	full := make([]string, 0, len(KnownCapabilities))
	for c := range KnownCapabilities {
		full = append(full, c)
	}

	t.Run("exact set in canonical form", func(t *testing.T) {
		if !IsFullCapabilitySet(full) {
			t.Error("the full KnownCapabilities set itself must report true")
		}
	})

	t.Run("exact set, mixed case and order", func(t *testing.T) {
		mixed := make([]string, len(full))
		for i, c := range full {
			mixed[len(full)-1-i] = lowerHalf(c)
		}
		if !IsFullCapabilitySet(mixed) {
			t.Error("normalization (case, order) must not affect the exact-match result")
		}
	})

	t.Run("one short of full is NOT exempt", func(t *testing.T) {
		// The exact "one capability missing" boundary — distinguishes a
		// genuine ceiling exemption from "close enough"/"large enough".
		almost := full[:len(full)-1]
		if IsFullCapabilitySet(almost) {
			t.Error("a set missing even one known capability must NOT report full")
		}
	})

	t.Run("duplicate padding cannot fake the length match", func(t *testing.T) {
		// len(allow) == len(KnownCapabilities) by repeating one entry, but the
		// UNIQUE normalized set is one short — must still report false. Kills
		// a mutant that compares raw slice length only.
		padded := append([]string{}, almostList(full)...)
		padded = append(padded, padded[0]) // duplicate to restore the original length
		if IsFullCapabilitySet(padded) {
			t.Error("duplicate-padded short list must not report full")
		}
	})

	t.Run("a real narrow module ceiling is NOT exempt", func(t *testing.T) {
		// The three-capability ceiling claude-tmux's credential unit actually
		// declares (modules/claude-tmux/manifest.yaml) — real-world "narrow,
		// not full" case, distinct from a synthetic near-miss.
		narrow := []string{"CAP_CHOWN", "CAP_DAC_OVERRIDE", "CAP_FOWNER"}
		if IsFullCapabilitySet(narrow) {
			t.Error("a narrow, real module ceiling must not report full")
		}
	})

	t.Run("empty is NOT exempt", func(t *testing.T) {
		if IsFullCapabilitySet(nil) {
			t.Error("an empty allow list (the strictest posture) must not report full")
		}
	})

	t.Run("unknown name never reports full", func(t *testing.T) {
		bad := append([]string{}, almostList(full)...)
		bad = append(bad, "CAP_MADE_UP")
		if IsFullCapabilitySet(bad) {
			t.Error("a set containing an unknown capability must not report full")
		}
	})
}

func almostList(full []string) []string {
	return append([]string{}, full[:len(full)-1]...)
}

func lowerHalf(s string) string {
	// normalizeCapName upper-cases and re-prefixes CAP_ regardless of input
	// case, so passing the bare suffix in lowercase still round-trips.
	return strings.ToLower(strings.TrimPrefix(s, "CAP_"))
}
