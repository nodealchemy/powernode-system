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

	// Pass 2 finds nothing (the write now succeeds) and publishes its own
	// (empty) result — only NOW may the published value actually clear.
	r.publishSecurityFailClosed()
	if got := r.SecurityFailClosedUnits(); len(got) != 0 {
		t.Errorf("expected the published value to clear once pass 2 published its empty result, got %v", got)
	}
}
