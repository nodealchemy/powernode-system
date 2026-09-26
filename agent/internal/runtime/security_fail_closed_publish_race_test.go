package runtime

import "testing"

// G4 (review round 5, mid-pass race): resetSecurityFailClosed runs at the TOP
// of RunOnce, before the attach/reattach loops that actually discover this
// pass's failures. If reset touched the PUBLISHED atomic value directly (as
// round-4 shipped), a heartbeat racing the mid-flight pass would read an
// empty set between the reset and this pass's own first recorded failure —
// SecurityFailClosedSensor reads that as "recovered", clears a real, still-
// open alarm, and then re-raises it once the pass finishes. The fix:
// resetSecurityFailClosed only clears the PENDING (non-atomic) accumulator;
// only publishSecurityFailClosed, called once after both attach loops
// finish, moves the published value.
func TestSecurityFailClosed_ResetDoesNotClearThePublishedValueUntilPublish(t *testing.T) {
	r := &Reconciler{}

	// Pass 1: records and publishes.
	r.recordSecurityFailClosed([]string{"unit-a.service"})
	r.publishSecurityFailClosed()
	if got := r.SecurityFailClosedUnits(); !containsArg(got, "unit-a.service") {
		t.Fatalf("test setup: expected unit-a.service published after pass 1, got %v", got)
	}

	// Simulate the TOP of pass 2: reset the pending accumulator, exactly as
	// RunOnce does before its attach/reattach loops run.
	r.resetSecurityFailClosed()

	// A heartbeat racing HERE — after reset, before pass 2's own attach loop
	// has recorded (or even started looking for) anything — must still see
	// pass 1's complete, still-valid result.
	if got := r.SecurityFailClosedUnits(); !containsArg(got, "unit-a.service") {
		t.Errorf("G4 REGRESSION: reset cleared the published value before pass 2 published its own result; a mid-pass heartbeat would read this as recovered, got %v", got)
	}

	// Pass 2 REACHES unit-a.service's security-policy decision (J3, review
	// round 5 REPLACEMENT review: applyModuleSecurityPolicy records this
	// unconditionally, success or failure — simulated directly here the same
	// way this test already drives recordSecurityFailClosed/
	// publishSecurityFailClosed directly rather than through attachModule)
	// and finds nothing (the write now succeeds) — only THEN, on publish, may
	// the published value actually clear for this unit. Omitting this
	// attempted-marking would make pass 2 look like a PARTIAL-VIEW tick that
	// never reached unit-a.service at all, which J3 requires to carry the
	// unit forward rather than clear it — a materially different scenario
	// from the one this test means to cover.
	r.securityPolicyAttemptedUnits = append(r.securityPolicyAttemptedUnits, "unit-a.service")
	r.publishSecurityFailClosed()
	if got := r.SecurityFailClosedUnits(); len(got) != 0 {
		t.Errorf("expected the published value to clear once pass 2 published its empty result, got %v", got)
	}
}
