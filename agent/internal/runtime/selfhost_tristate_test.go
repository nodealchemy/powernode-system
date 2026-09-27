package runtime

import (
	"errors"
	"testing"
)

// Round Y (IMP-caef5c00d63f, N2 from the round-X confirm review): a probe
// failure must resolve to selfHostUnknown, not the same answer as a
// positively-confirmed remote node — see selfHostState's own doc for the
// outage class collapsing the two caused (a self-hosted node restarting its
// own control plane on its first tick after a resolver hiccup, before the
// latch ever had a chance to arm).

func TestSelfHostState_LookupErrorIsUnknownNotNo(t *testing.T) {
	withLookups(t, nil, []string{"192.0.2.227"}, errors.New("no such host"))
	r := selfHostReconciler(t, "https://ops-hub.example.test")

	if got := r.selfHostState(); got != selfHostUnknown {
		t.Errorf("selfHostState() = %v, want selfHostUnknown", got)
	}
}

func TestSelfHostState_InterfaceListErrorIsUnknown(t *testing.T) {
	origHost, origLocal := lookupHostIPs, localInterfaceIPs
	lookupHostIPs = func(string) ([]string, error) { return []string{"192.0.2.227"}, nil }
	localInterfaceIPs = func() ([]string, error) { return nil, errors.New("interface enumeration failed") }
	t.Cleanup(func() { lookupHostIPs, localInterfaceIPs = origHost, origLocal })
	r := selfHostReconciler(t, "https://ops-hub.example.test")

	if got := r.selfHostState(); got != selfHostUnknown {
		t.Errorf("selfHostState() = %v, want selfHostUnknown", got)
	}
}

func TestSelfHostState_UnparsableURLIsUnknown(t *testing.T) {
	withLookups(t, nil, []string{"192.0.2.227"}, nil)
	// hostFromURL returns "" for a string with no host component at all.
	r := selfHostReconciler(t, "://not-a-url")

	if got := r.selfHostState(); got != selfHostUnknown {
		t.Errorf("selfHostState() = %v, want selfHostUnknown", got)
	}
}

func TestSelfHostState_EmptyPlatformURLIsDefinitelyNo(t *testing.T) {
	withLookups(t, nil, []string{"192.0.2.227"}, nil)
	r := selfHostReconciler(t, "")

	if got := r.selfHostState(); got != selfHostNo {
		t.Errorf("selfHostState() = %v, want selfHostNo (no platform configured at all)", got)
	}
}

func TestRestartPermitted_FalseOnUnknownAndYes_TrueOnlyOnDefiniteNo(t *testing.T) {
	// Unknown: a lookup failure.
	withLookups(t, nil, []string{"192.0.2.227"}, errors.New("no such host"))
	r := selfHostReconciler(t, "https://ops-hub.example.test")
	if r.restartPermitted() {
		t.Error("X2/N2 REGRESSION: restartPermitted() must be false on Unknown detection")
	}

	// Yes: platform resolves to a local address.
	withLookups(t, map[string][]string{"ops-hub.example.test": {"192.0.2.227"}},
		[]string{"192.0.2.227"}, nil)
	r2 := selfHostReconciler(t, "https://ops-hub.example.test")
	if r2.restartPermitted() {
		t.Error("restartPermitted() must be false when self-hosted")
	}

	// Definite No: platform resolves, does not match any local address.
	withLookups(t, map[string][]string{"dev.example.test": {"192.0.2.22"}},
		[]string{"192.0.2.99"}, nil)
	r3 := selfHostReconciler(t, "https://dev.example.test")
	if !r3.restartPermitted() {
		t.Error("restartPermitted() must be true on a positively-confirmed remote node")
	}
}

// The latch must survive a LATER error even for restartPermitted(), not
// just selfHosted() — once Yes, it stays Yes and restarts stay withheld.
func TestRestartPermitted_LatchedYesSurvivesALaterLookupError(t *testing.T) {
	withLookups(t, map[string][]string{"ops-hub.example.test": {"192.0.2.227"}},
		[]string{"192.0.2.227"}, nil)
	r := selfHostReconciler(t, "https://ops-hub.example.test")
	if r.restartPermitted() {
		t.Fatal("precondition: expected restartPermitted()=false once self-hosted")
	}

	withLookups(t, nil, nil, errors.New("no such host"))
	if r.restartPermitted() {
		t.Error("a latched self-hosted node must stay restart-withheld through a later DNS failure")
	}
}
