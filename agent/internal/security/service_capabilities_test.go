package security

import (
	"reflect"
	"strings"
	"testing"
)

// IMP-caef5c00d63f — the module's security.capabilities is a CEILING; a
// service's own set is that unit's effective set and must be a subset of it.
// Absent inherits the whole ceiling; an explicit [] is zero.

var hubBackendCeiling = []string{"CAP_CHOWN", "CAP_FOWNER", "CAP_DAC_OVERRIDE"}

func TestResolveServiceCapabilities_AbsentInheritsCeiling(t *testing.T) {
	got, err := ResolveServiceCapabilities(hubBackendCeiling, false, nil)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := []string{"CAP_CHOWN", "CAP_DAC_OVERRIDE", "CAP_FOWNER"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("absent key: got %v, want the whole ceiling %v", got, want)
	}
}

// The case the whole design exists for: the non-root rails unit declares []
// under a ceiling that grants rails-setup CHOWN/FOWNER/DAC_OVERRIDE. A length
// check would read [] as "nothing declared" and hand rails the ceiling.
func TestResolveServiceCapabilities_ExplicitEmptyIsZeroUnderNonEmptyCeiling(t *testing.T) {
	got, err := ResolveServiceCapabilities(hubBackendCeiling, true, []string{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got) != 0 {
		t.Fatalf("explicit []: got %v, want ZERO capabilities", got)
	}
}

func TestResolveServiceCapabilities_NonEmptySubsetIsOwnSet(t *testing.T) {
	got, err := ResolveServiceCapabilities(hubBackendCeiling, true, []string{"cap_chown"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !reflect.DeepEqual(got, []string{"CAP_CHOWN"}) {
		t.Fatalf("subset: got %v, want [CAP_CHOWN] (normalized)", got)
	}
}

func TestResolveServiceCapabilities_ExceedingTheCeilingIsRefused(t *testing.T) {
	got, err := ResolveServiceCapabilities(hubBackendCeiling, true, []string{"CAP_CHOWN", "CAP_SYS_ADMIN"})
	if err == nil {
		t.Fatalf("a service set wider than the module ceiling must be refused, got %v", got)
	}
	if !strings.Contains(err.Error(), "CAP_SYS_ADMIN") {
		t.Fatalf("error must name the capability outside the ceiling: %v", err)
	}
}

func TestResolveServiceCapabilities_EmptyCeilingRefusesAnyGrant(t *testing.T) {
	if _, err := ResolveServiceCapabilities(nil, true, []string{"CAP_NET_BIND_SERVICE"}); err == nil {
		t.Fatalf("a grant under an empty ceiling must be refused")
	}
}

func TestResolveServiceCapabilities_UnknownNameIsRefused(t *testing.T) {
	if _, err := ResolveServiceCapabilities([]string{"CAP_CHOWN", "CAP_NOT_A_THING"}, false, nil); err == nil {
		t.Fatalf("an unknown ceiling capability must be refused")
	}
	if _, err := ResolveServiceCapabilities(hubBackendCeiling, true, []string{"CAP_NOT_A_THING"}); err == nil {
		t.Fatalf("an unknown service capability must be refused")
	}
}

// Review finding P4: a ceiling that lists a capability twice (or as cap_chown
// and CAP_CHOWN) must render the same drop-in, and therefore the same stamp,
// as one that lists it once — otherwise a no-op manifest edit re-attaches.
func TestRenderCapabilityDropInBody_DeduplicatesEquivalentNames(t *testing.T) {
	once, err := renderCapabilityDropInBody([]string{"CAP_CHOWN", "CAP_FOWNER"})
	if err != nil {
		t.Fatal(err)
	}
	twice, err := renderCapabilityDropInBody([]string{"cap_chown", "CAP_FOWNER", "CAP_CHOWN"})
	if err != nil {
		t.Fatal(err)
	}
	if once != twice {
		t.Fatalf("duplicate capability changed the rendered drop-in:\n once:\n%s\n twice:\n%s", once, twice)
	}
	if RenderedPolicyHash(&Policy{Capabilities: []string{"CAP_CHOWN", "chown"}}, true) !=
		RenderedPolicyHash(&Policy{Capabilities: []string{"CAP_CHOWN"}}, true) {
		t.Fatal("a duplicated ceiling entry moved the policy stamp")
	}
}
