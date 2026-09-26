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
	got, _, err := ResolveServiceCapabilities(hubBackendCeiling, false, nil)
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
	got, _, err := ResolveServiceCapabilities(hubBackendCeiling, true, []string{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got) != 0 {
		t.Fatalf("explicit []: got %v, want ZERO capabilities", got)
	}
}

func TestResolveServiceCapabilities_NonEmptySubsetIsOwnSet(t *testing.T) {
	got, _, err := ResolveServiceCapabilities(hubBackendCeiling, true, []string{"cap_chown"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !reflect.DeepEqual(got, []string{"CAP_CHOWN"}) {
		t.Fatalf("subset: got %v, want [CAP_CHOWN] (normalized)", got)
	}
}

func TestResolveServiceCapabilities_ExceedingTheCeilingIsRefused(t *testing.T) {
	got, _, err := ResolveServiceCapabilities(hubBackendCeiling, true, []string{"CAP_CHOWN", "CAP_SYS_ADMIN"})
	if err == nil {
		t.Fatalf("a service set wider than the module ceiling must be refused, got %v", got)
	}
	if !strings.Contains(err.Error(), "CAP_SYS_ADMIN") {
		t.Fatalf("error must name the capability outside the ceiling: %v", err)
	}
}

func TestResolveServiceCapabilities_EmptyCeilingRefusesAnyGrant(t *testing.T) {
	if _, _, err := ResolveServiceCapabilities(nil, true, []string{"CAP_NET_BIND_SERVICE"}); err == nil {
		t.Fatalf("a grant under an empty ceiling must be refused")
	}
}

// L4 (review round 7, MEDIUM): K5b already made an unrecognized MODULE-WIDE
// capability name (Policy.DropUnknownCapabilities) narrower-never-wider
// rather than a hard refusal, for a version-skew manifest naming a newer
// agent's capability. This is the SAME mirror for the two lists
// ResolveServiceCapabilities itself resolves — the ceiling AND the
// per-service declared set — neither of which K5b's own scope touched.
func TestResolveServiceCapabilities_UnknownCeilingNameIsDroppedNotRefused(t *testing.T) {
	got, dropped, err := ResolveServiceCapabilities([]string{"CAP_CHOWN", "CAP_NOT_A_THING"}, false, nil)
	if err != nil {
		t.Fatalf("L4 REGRESSION: expected an unrecognized ceiling name to be DROPPED, not refused, got error: %v", err)
	}
	if !reflect.DeepEqual(got, []string{"CAP_CHOWN"}) {
		t.Fatalf("got %v, want the ceiling narrowed to [CAP_CHOWN] (CAP_NOT_A_THING dropped)", got)
	}
	if len(dropped) != 1 || dropped[0] != "CAP_NOT_A_THING" {
		t.Errorf("expected dropped=[CAP_NOT_A_THING], got %v", dropped)
	}
}

func TestResolveServiceCapabilities_UnknownServiceNameIsDroppedNotRefused(t *testing.T) {
	got, dropped, err := ResolveServiceCapabilities(hubBackendCeiling, true, []string{"CAP_CHOWN", "CAP_NOT_A_THING"})
	if err != nil {
		t.Fatalf("L4 REGRESSION: expected an unrecognized service capability name to be DROPPED, not refused, got error: %v", err)
	}
	if !reflect.DeepEqual(got, []string{"CAP_CHOWN"}) {
		t.Fatalf("got %v, want the service's own set narrowed to [CAP_CHOWN] (CAP_NOT_A_THING dropped)", got)
	}
	if len(dropped) != 1 || dropped[0] != "CAP_NOT_A_THING" {
		t.Errorf("expected dropped=[CAP_NOT_A_THING], got %v", dropped)
	}
}

// A bare name (no CAP_ prefix) is a DIFFERENT SPELLING of a name this agent
// DOES recognize — normalizeCapName's own job — never an "unrecognized name"
// in the L4 sense above. It must keep normalizing successfully, not get
// swept into the new drop path.
func TestResolveServiceCapabilities_BareNameStillNormalizesNotDropped(t *testing.T) {
	got, dropped, err := ResolveServiceCapabilities([]string{"chown", "CAP_FOWNER"}, false, nil)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(dropped) != 0 {
		t.Errorf("L4 REGRESSION: a bare-but-known name must NOT be reported as dropped, got dropped=%v", dropped)
	}
	want := []string{"CAP_CHOWN", "CAP_FOWNER"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("bare name: got %v, want normalized %v", got, want)
	}
}

// Review finding P4: a ceiling that lists a capability twice (or as cap_chown
// and CAP_CHOWN) must render the same drop-in, and therefore the same stamp,
// as one that lists it once — otherwise a no-op manifest edit re-attaches.
func TestRenderCapabilityDropInBody_DeduplicatesEquivalentNames(t *testing.T) {
	once, err := RenderCapabilityDropInBody([]string{"CAP_CHOWN", "CAP_FOWNER"})
	if err != nil {
		t.Fatal(err)
	}
	twice, err := RenderCapabilityDropInBody([]string{"cap_chown", "CAP_FOWNER", "CAP_CHOWN"})
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
