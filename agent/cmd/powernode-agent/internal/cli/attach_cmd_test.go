package cli

import (
	"errors"
	"fmt"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/runtime"
)

// J2 (review round 5): AttachOne runs inside this CLI's own short-lived
// process — publishing its refusal into a Reconciler nobody reads back
// (H1's approach) has no production effect. attachErrorResult is the actual
// signal: a distinct exit code plus the refused units named in Details, so
// an operator or wrapper script can tell "the module's own security policy
// refused it" apart from an ordinary mount/pull failure.
func TestAttachErrorResult_SecurityFailClosedGetsDistinctExitCodeAndUnits(t *testing.T) {
	secErr := &runtime.SecurityFailClosedError{
		ModuleID: "m1",
		Units:    []string{"powernode-m1-app.service"},
	}

	res, cmdErr := attachErrorResult("m1", secErr)

	if res.ExitCode != ExitSecurityFailClosed {
		t.Errorf("expected ExitCode=%d (ExitSecurityFailClosed), got %d", ExitSecurityFailClosed, res.ExitCode)
	}
	if res.Status != "error" {
		t.Errorf("expected Status=\"error\", got %q", res.Status)
	}
	units, ok := res.Details["refused_units"].([]string)
	if !ok || len(units) != 1 || units[0] != "powernode-m1-app.service" {
		t.Errorf("expected Details[\"refused_units\"]=[powernode-m1-app.service], got %v", res.Details["refused_units"])
	}
	if res.Details["module_id"] != "m1" {
		t.Errorf("expected Details[\"module_id\"]=\"m1\", got %v", res.Details["module_id"])
	}

	var ce *CommandError
	if !errors.As(cmdErr, &ce) {
		t.Fatalf("expected a *CommandError, got %T: %v", cmdErr, cmdErr)
	}
	if ce.Code != ExitSecurityFailClosed {
		t.Errorf("expected CommandError.Code=%d, got %d", ExitSecurityFailClosed, ce.Code)
	}
}

// An attach failure that is NOT a security-policy refusal (a mount/pull
// problem, an invalid policy, an unapproved privileged request) must keep
// using ExitMountFailed — attachErrorResult must not widen
// ExitSecurityFailClosed to every attach error.
func TestAttachErrorResult_OrdinaryFailureKeepsExitMountFailed(t *testing.T) {
	res, cmdErr := attachErrorResult("m1", fmt.Errorf("mount erofs: no such file"))

	if res.ExitCode != ExitMountFailed {
		t.Errorf("expected ExitCode=%d (ExitMountFailed), got %d", ExitMountFailed, res.ExitCode)
	}
	if res.Details != nil {
		t.Errorf("an ordinary failure must not carry a refused_units Details block, got %v", res.Details)
	}

	var ce *CommandError
	if !errors.As(cmdErr, &ce) {
		t.Fatalf("expected a *CommandError, got %T: %v", cmdErr, cmdErr)
	}
	if ce.Code != ExitMountFailed {
		t.Errorf("expected CommandError.Code=%d, got %d", ExitMountFailed, ce.Code)
	}
}
