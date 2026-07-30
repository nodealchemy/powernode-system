package runtime

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

// systemctlFunc runs systemctl and returns its stdout EVEN WHEN IT EXITS
// NON-ZERO. That is the entire reason this seam exists instead of reusing
// mount.Runner: `systemctl is-system-running` exits 1 to report `degraded`, and
// mount.ExecRunner.Output discards stdout on any non-zero exit (it returns
// `nil, err`). Routed through it, the one state this prober most needs to read
// would arrive as an empty string — the prober would report "not ready" for a
// system that had finished booting, and the bless would never happen.
//
// Deliberately not fixed by relaxing ExecRunner: every other caller in the
// agent treats a non-zero exit as a hard failure with no usable output, and
// widening that contract to suit one caller invites the opposite bug elsewhere.
type systemctlFunc func(ctx context.Context, args ...string) ([]byte, error)

// systemctlProbeTimeout bounds a single probe, mirroring the HTTP prober's 5s.
//
// Load-bearing, not defensive dressing. `systemctl is-system-running` answers
// over D-Bus, and a wedged or unresponsive dbus is an entirely plausible state
// on exactly the sort of half-broken boot this gate exists to judge. With no
// deadline, Healthy would never return, the confirmer's loop would never take
// another turn, and the ten-minute stuck-gate warning — which is evaluated only
// after a probe comes back — would never fire. The one failure mode the warning
// was added for would be the one it could not report.
const systemctlProbeTimeout = 5 * time.Second

func execSystemctl(ctx context.Context, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, systemctlProbeTimeout)
	defer cancel()
	// exec.Cmd.Output() populates stdout alongside an *ExitError, so both are
	// returned as-is and the caller decides which one is authoritative.
	out, err := exec.CommandContext(ctx, "systemctl", args...).Output()
	return out, err
}

// systemdReadyProber answers "did this boot finish?" for nodes that expose no
// application health endpoint.
//
// It is the default gate because the previous default was a loopback HTTPS
// probe of https://127.0.0.1/up — a URL only a node running the platform's own
// web tier can ever answer. Every other node in the fleet therefore failed the
// gate on every probe, forever, and a perfectly healthy image was left
// unblessed to silently revert on its next reboot. A default gate has to be one
// that an ordinary node can actually pass.
type systemdReadyProber struct {
	run systemctlFunc
	// reconcileOK reports whether the agent's own module reconcile has completed
	// successfully this boot. Nil disables the conjunct (tests).
	reconcileOK func() bool
}

func newSystemdReadyProber(reconcileOK func() bool) *systemdReadyProber {
	return &systemdReadyProber{run: execSystemctl, reconcileOK: reconcileOK}
}

// Healthy reports true once systemd has reached its default target.
//
// `running` and `degraded` BOTH pass, and the inclusion of degraded is the
// load-bearing decision here, not an oversight. Both mean the same thing about
// the question actually being asked — the boot completed — and they differ only
// in whether some unit somewhere is failed.
//
// Blessing only on `running` would have re-created the bug this replaces in a
// new costume. A single unrelated failed unit would block every bless on that
// node forever: on ops-cell that is claude-tmux, which crash-loops whenever its
// Vault credential is absent and has nothing to do with whether the OS image
// booted. The node would have gone on silently reverting good images, and the
// cause would have looked entirely different from the last one.
//
// The alternative to blessing is not "an operator investigates a degraded
// node". It is "the node quietly reverts to the previous image on its next
// reboot", which destroys the evidence. A degraded node that stays on the image
// it booted is strictly more debuggable than one that mysteriously went
// backwards. Rolling back the whole OS over one failed unit is also far more
// than the failure warrants — and it is the same latitude the HTTP gate already
// grants hubs, since /up returns 200 regardless of unrelated unit failures.
//
// Everything else fails closed: `starting`/`initializing` mean the boot has not
// finished yet, `maintenance` means it dropped to emergency/rescue,
// `stopping` means we are on the way down, and `offline`/`unknown` mean systemd
// cannot be interrogated at all.
func (p *systemdReadyProber) Healthy(ctx context.Context) (bool, error) {
	// systemd cannot see the failure this conjunct catches. A UKI that breaks
	// module COMPOSITION reports a clean `running` with nothing failed — the
	// units were never installed, so they were never there to fail — and that is
	// the regression class A/B rollback exists for: the /sbin shadowing that made
	// all of /usr/sbin vanish, the module overlay that shadowed the disk image.
	// On systemd's evidence alone the gate would bless them.
	//
	// The agent's own composition state does see an attach or union-mount
	// failure, and the two together separate "this image broke composition"
	// (must NOT bless) from "one module's service is unhappy" (must bless — the
	// claude-tmux-without-a-credential case that `degraded` is deliberately
	// permitted for). Checked before shelling out, since it is free and decisive.
	//
	// See ComposedOK for what this does and does NOT prove — notably that it is
	// absence-of-failure, not proof of success, and deliberately independent of
	// whether the platform was reachable.
	if p.reconcileOK != nil && !p.reconcileOK() {
		return false, nil
	}
	out, err := p.run(ctx, "is-system-running")
	// Parse stdout FIRST and treat the exit code as advisory. Inverting this —
	// checking err before reading the state — is the natural way to write it and
	// is wrong, because `degraded` always arrives with a non-zero exit.
	switch state := strings.TrimSpace(string(out)); state {
	case "running", "degraded":
		return true, nil
	case "":
		// No state at all: systemctl is missing, unrunnable, or produced
		// nothing. Report the error rather than a bare false — a probe error
		// resets the consecutive run either way, but only an error is
		// distinguishable from "booted, but not ready yet" in the logs.
		if err != nil {
			return false, fmt.Errorf("systemctl is-system-running: %w", err)
		}
		return false, fmt.Errorf("systemctl is-system-running: empty state")
	default:
		return false, nil
	}
}
