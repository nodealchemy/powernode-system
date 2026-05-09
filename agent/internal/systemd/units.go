// Package systemd wraps systemctl invocations behind the mount.Runner
// abstraction so the M2.D CLI commands (attach, detach, init) and the
// reconcile goroutine share one entry point. Tests use
// mount.RecorderRunner to assert exact command sequences.
package systemd

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// Action is the verb passed to systemctl. The agent supports the
// subset of systemctl actions that operate on a single unit. Reload
// is included because long-lived services (nginx, sshd) commonly
// expose SIGHUP-driven config reloads as `systemctl reload <unit>`.
type ActionVerb string

const (
	Start   ActionVerb = "start"
	Stop    ActionVerb = "stop"
	Restart ActionVerb = "restart"
	Reload  ActionVerb = "reload"
	Status  ActionVerb = "status"
)

// validActions limits ActionVerb values to the fixed allow-list. Stops
// callers from passing arbitrary strings (e.g., "kill" which has
// different syntax) into the wrapper.
var validActions = map[ActionVerb]struct{}{
	Start: {}, Stop: {}, Restart: {}, Reload: {}, Status: {},
}

// IsValid returns true if v is a recognized ActionVerb.
func (v ActionVerb) IsValid() bool {
	_, ok := validActions[v]
	return ok
}

// Action runs `systemctl <verb> <unit>` via the runner. Returns nil
// on success, error wrapping the runner output on failure.
//
// `restart` is implemented as systemctl restart (atomic from systemd's
// view), not stop+start, so unit dependencies stay coherent. Callers
// that need separate stop+start orchestration (e.g., reverse-order
// detach) should issue separate Stop calls.
func Action(ctx context.Context, runner mount.Runner, unit string, verb ActionVerb) error {
	if runner == nil {
		return errors.New("systemd.Action: nil runner")
	}
	if unit == "" {
		return errors.New("systemd.Action: empty unit")
	}
	if !verb.IsValid() {
		return fmt.Errorf("systemd.Action: invalid verb %q", verb)
	}
	if err := unitNameValid(unit); err != nil {
		return err
	}
	if err := runner.Run(ctx, "systemctl", string(verb), unit); err != nil {
		return fmt.Errorf("systemctl %s %s: %w", verb, unit, err)
	}
	return nil
}

// IsActive returns true iff `systemctl is-active <unit>` returns
// "active". Used by lifecycle handlers to short-circuit idempotent
// work (e.g., `start` no-ops when the unit is already active).
func IsActive(ctx context.Context, runner mount.Runner, unit string) (bool, error) {
	if runner == nil {
		return false, errors.New("systemd.IsActive: nil runner")
	}
	if err := unitNameValid(unit); err != nil {
		return false, err
	}
	out, err := runner.Output(ctx, "systemctl", "is-active", unit)
	// is-active exits non-zero for any state other than "active". The
	// stdout still carries the state, which is what we care about.
	if err != nil && len(out) == 0 {
		return false, nil
	}
	return strings.TrimSpace(string(out)) == "active", nil
}

// DaemonReload runs `systemctl daemon-reload`. Used by callers after
// dropping new unit files into /etc/systemd/system.
func DaemonReload(ctx context.Context, runner mount.Runner) error {
	if runner == nil {
		return errors.New("systemd.DaemonReload: nil runner")
	}
	if err := runner.Run(ctx, "systemctl", "daemon-reload"); err != nil {
		return fmt.Errorf("systemctl daemon-reload: %w", err)
	}
	return nil
}

// unitNameValid rejects unit names that would let a caller inject
// extra systemctl flags or commands (defense in depth — Run already
// passes args separately, but reject up-front so failures are explicit
// rather than executing some malformed unit name).
func unitNameValid(unit string) error {
	if unit == "" {
		return errors.New("empty unit name")
	}
	if strings.ContainsAny(unit, " \t\n\r;|&`$") {
		return fmt.Errorf("invalid unit name %q (contains shell metachar)", unit)
	}
	if strings.HasPrefix(unit, "-") {
		return fmt.Errorf("invalid unit name %q (leading dash would parse as a flag)", unit)
	}
	return nil
}
