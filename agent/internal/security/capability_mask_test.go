package security

import (
	"testing"
)

// TestCapabilityBitsMatchesKnownCapabilities (round Y) pins capabilityBits'
// own key set identical to KnownCapabilities — the two must never silently
// drift apart, since CapabilityMask relies on every KnownCapabilities name
// having a bit entry (see CapabilityMask's own "unreachable" defensive
// branch).
func TestCapabilityBitsMatchesKnownCapabilities(t *testing.T) {
	if len(capabilityBits) != len(KnownCapabilities) {
		t.Fatalf("capabilityBits has %d entries, KnownCapabilities has %d", len(capabilityBits), len(KnownCapabilities))
	}
	for name := range KnownCapabilities {
		if _, ok := capabilityBits[name]; !ok {
			t.Errorf("KnownCapabilities entry %s has no capabilityBits mapping", name)
		}
	}
	for name := range capabilityBits {
		if _, ok := KnownCapabilities[name]; !ok {
			t.Errorf("capabilityBits entry %s is not in KnownCapabilities", name)
		}
	}
	// Bit indices are a fixed kernel ABI (linux/capability.h) — no two names
	// may share a bit, and every bit must be in [0,40] for the 41 known caps.
	seen := make(map[uint]string, len(capabilityBits))
	for name, bit := range capabilityBits {
		if bit > 40 {
			t.Errorf("%s has out-of-range bit %d (expected 0-40)", name, bit)
		}
		if other, dup := seen[bit]; dup {
			t.Errorf("bit %d assigned to both %s and %s", bit, name, other)
		}
		seen[bit] = name
	}
}

// TestCapabilityMask_KnownCombination pins three well-known low bits
// (CAP_CHOWN=0, CAP_DAC_OVERRIDE=1, CAP_FOWNER=3) to the exact mask value
// 0xb, both locking in the kernel ABI ordering and giving a mutation on the
// OR/shift logic something concrete to fail against.
func TestCapabilityMask_KnownCombination(t *testing.T) {
	mask, err := CapabilityMask([]string{"CAP_CHOWN", "CAP_FOWNER", "CAP_DAC_OVERRIDE"})
	if err != nil {
		t.Fatalf("CapabilityMask: %v", err)
	}
	if mask != 0xb {
		t.Errorf("CapabilityMask(CAP_CHOWN,CAP_FOWNER,CAP_DAC_OVERRIDE) = %#x, want 0xb", mask)
	}
}

// TestCapabilityMask_EmptyIsZero pins the empty-allow case: no capability
// bits set at all, the strictest posture (mirrors RenderCapabilityDropInBody's
// own empty-list handling).
func TestCapabilityMask_EmptyIsZero(t *testing.T) {
	mask, err := CapabilityMask(nil)
	if err != nil {
		t.Fatalf("CapabilityMask(nil): %v", err)
	}
	if mask != 0 {
		t.Errorf("CapabilityMask(nil) = %#x, want 0", mask)
	}
}

// TestCapabilityMask_UnknownNameErrors mirrors RenderCapabilityDropInBody's
// own validation: a name normalizeCapName does not recognize must error, not
// silently produce a mask missing that bit.
func TestCapabilityMask_UnknownNameErrors(t *testing.T) {
	if _, err := CapabilityMask([]string{"CAP_MADE_UP"}); err == nil {
		t.Error("expected an error for an unknown capability name, got nil")
	}
}

// TestParseProcCapMask_FullSet pins the standard 16-hex-digit /proc/<pid>/status
// Cap* field shape and confirms it decodes to the full 41-bit known set
// (2^41 - 1).
func TestParseProcCapMask_FullSet(t *testing.T) {
	mask, err := ParseProcCapMask("000001ffffffffff")
	if err != nil {
		t.Fatalf("ParseProcCapMask: %v", err)
	}
	want := uint64(1)<<41 - 1
	if mask != want {
		t.Errorf("ParseProcCapMask(\"000001ffffffffff\") = %#x, want %#x", mask, want)
	}
}

// TestParseProcCapMask_Zero pins the all-zero case (a fully unconfined-of-
// nothing / bare process with no capabilities at all).
func TestParseProcCapMask_Zero(t *testing.T) {
	mask, err := ParseProcCapMask("0000000000000000")
	if err != nil {
		t.Fatalf("ParseProcCapMask: %v", err)
	}
	if mask != 0 {
		t.Errorf("ParseProcCapMask(zeros) = %#x, want 0", mask)
	}
}

// TestParseProcCapMask_RejectsGarbage guards against a malformed /proc read
// (a renamed field, a truncated status file) silently parsing as a bogus
// mask instead of surfacing an error the caller can treat as "not probed".
func TestParseProcCapMask_RejectsGarbage(t *testing.T) {
	if _, err := ParseProcCapMask("not-hex"); err == nil {
		t.Error("expected an error for a non-hex field, got nil")
	}
}
