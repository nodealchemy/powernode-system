package runtime

import (
	"context"
	"fmt"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/bootupgrade"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// BootConfirmer blesses a pending A/B boot slot once the node's OWN composed
// application has been healthy for N consecutive probes (INV-4).
//
// It replaces gating the bless on "the first successful heartbeat", which was
// identity-gated, not health-gated: it asked *can I reach the platform*, not
// *did this image come up*. Those differ in both directions.
//
//   - A node whose image booted perfectly but whose platform link is briefly
//     down does not bless. Observed on ops-hub 2026-07-26: an ingress race
//     served the default TLS cert for ~3 minutes, every heartbeat failed
//     certificate verification, and a healthy upgrade sat unblessed — two more
//     reboots would have auto-reverted a good image.
//   - Worse in the other direction: reaching the platform says nothing about
//     whether the composed stack on THIS node works. An image that boots far
//     enough to heartbeat but whose services never come up would be blessed,
//     disarming the rollback that exists precisely for that case.
//
// On a self-hosted control plane the two are especially tangled — the platform
// the node would heartbeat to IS the node — so the only honest signal is the
// node probing its own composed app.
//
// The gate reads the same SiteSetting-delivered AppHealthCfg (url /
// required_consecutive / poll_interval_seconds) that the LKG capturer does,
// carried on the boot breadcrumb, so it can be retuned centrally with no new
// agent binary.
//
// The two gates NO LONGER agree in all cases, and that is deliberate rather than
// drift. When no URL is configured this one falls back to a local systemd
// readiness probe while LKG capture keeps the loopback default, because
// promoting an LKG is a permanent composition freeze on a self-hosted control
// plane whereas failing to bless costs a reverted image. Same config, different
// blast radius — see the note in Service.
//
// What a node with NO configured health URL is gated on was itself the next
// defect. It used to be the same loopback https://127.0.0.1/up — an endpoint
// only a node running the platform's web tier can answer — so every other node
// in the fleet failed the gate on every probe for the entire boot, and a
// perfectly good image sat unblessed until it silently reverted. Those nodes now
// get a local systemd readiness gate they can actually pass (systemdready.go).
// "Unconfigured" and "explicitly loopback" must therefore stay DISTINGUISHABLE
// all the way down from Service — see AppHealthURL below.
//
// A hub must NOT be demoted to that local gate, and cannot be told not to be:
// nothing in production sets Config.AppHealthURL, and the breadcrumb's URL comes
// from a fleet-global SiteSetting (system.boot_lkg.app_health_url, served
// identically to every node), so configuring it to protect a hub would re-impose
// the unpassable loopback gate on the whole fleet. On a self-hosted control
// plane no setting can arrive at all — such a node boots FromLKG, taking
// AppHealth from a permanently frozen LKG. So the node decides for itself, from
// its own composed module set (webtier.go): compose the platform's web tier and
// you are gated on /up, whether or not anyone remembered to configure it.
//
// The local gate is deliberately NOT just systemd. See systemdReadyProber.
type BootConfirmer struct {
	// BreadcrumbPath supplies the AppHealthCfg override for this boot.
	BreadcrumbPath string
	// AppHealthURL is the app health endpoint to probe, when this node HAS one.
	//
	// EMPTY MEANS UNCONFIGURED, and must be preserved as such by callers rather
	// than defaulted to a loopback URL. That defaulting was the bug: it made
	// "this node runs the platform's web tier" indistinguishable from "nobody
	// told this node anything", so every non-hub node in the fleet was gated on
	// an endpoint it could never answer. An unconfigured node falls back to a
	// local systemd readiness gate instead (see systemdready.go).
	AppHealthURL string
	// Hostname is the SNI/Host header for the loopback probe.
	Hostname string
	// BootedGitSHA identifies the image actually running, from /proc/cmdline.
	BootedGitSHA string
	// Runner performs the ESP mutations (bless / set-default).
	Runner mount.Runner
	// Prober overrides the health probe (tests).
	Prober HealthProber
	// ReconcileOK reports that no module attach or union-mount failure has been
	// observed this boot (Reconciler.ComposedOK). Conjoined with the local
	// systemd gate, which alone cannot see a broken composition — see
	// systemdReadyProber.Healthy. Nil disables the conjunct.
	ReconcileOK func() bool
	// RequiredConsecutive / PollInterval override the defaults (3 / 15s).
	RequiredConsecutive int
	PollInterval        time.Duration
	// GateWarnAfter is how long the gate may go unpassed before saying so
	// (default 10 minutes). A gate that cannot be passed is otherwise perfectly
	// silent — the node just never blesses, and the only symptom is an image
	// that reverts on a reboot nobody connects to it days later.
	GateWarnAfter time.Duration

	OnError func(stage string, err error)
}

// Run settles the evidence-based half of the verdict immediately, then gates the
// bless on health. It returns once the boot is confirmed, or when ctx ends.
//
// The split matters: only BLESSING needs proof that this image came up.
// Recording that a trial fell back needs proof of which slot booted, which
// systemd-boot supplies outright, and holding that behind a health gate meant
// the rolled-back nodes it exists for were the ones least able to reach it.
func (c *BootConfirmer) Run(ctx context.Context) error {
	// Nothing to do is the overwhelmingly common case — do not probe, do not
	// touch the ESP, do not hold anything. Cheap enough to re-check rather than
	// assume, since a task-lease upgrade can set Pending after boot.
	//
	// Ask bootupgrade rather than testing Pending here. "Pending is empty" is NOT
	// "nothing to do": a boot onto a slot whose earlier attempt fell back arrives
	// with Pending already cleared and still needs blessing, and testing Pending
	// at this gate made that entire path unreachable — the bless logic would sit
	// in ConfirmBoot and never once run. (ops-hub 2026-07-28, blessed by hand.)
	if !bootupgrade.ConfirmNeeded(c.BootedGitSHA) {
		return nil
	}

	// Settle the half of the verdict that health has no bearing on, BEFORE
	// waiting on the gate. If systemd-boot says we booted the other slot, the
	// trial provably fell back; making that conclusion wait on a health gate
	// meant a rolled-back node — the least likely of all to look healthy — could
	// never record its own rollback.
	if cleared, err := bootupgrade.ResolveFallback(c.BootedGitSHA); err != nil {
		c.onError("boot_fallback_resolve", err)
	} else if cleared {
		// Say so. This path ERASES boot state, and before it existed the
		// surviving Pending record was itself the operator-visible trace that an
		// upgrade had been attempted and had not taken. Clearing it silently
		// removes the one breadcrumb someone would look for when asking why a
		// dispatched image never landed.
		c.onError("boot_fallback_resolved", fmt.Errorf(
			"boot slot trial did not take: this boot came up on a different slot, so the attempt "+
				"was recorded as rolled back and cleared (image %s)", shortSHA(c.BootedGitSHA)))
		if !bootupgrade.ConfirmNeeded(c.BootedGitSHA) {
			// The attempt is resolved and nothing is owed. Blessing is the only
			// work left behind the gate, and there is none — do not probe.
			return nil
		}
	}

	gate := c.resolveGate()
	prober, required, interval := gate.prober, gate.required, gate.interval

	// Announce WHICH gate this boot picked, once, while it is still working.
	// Gate selection is otherwise invisible unless it gets stuck, so the one
	// question an operator asks after a mystery revert — "what was this node
	// even probing?" — had no answer in the log. It also lets a node self-report
	// that it detected its own web tier, which is the only practical way to
	// confirm that on a host whose /persist is unreadable without root.
	c.onError("boot_confirm_gate_selected", fmt.Errorf(
		"gating bless on %s (%d consecutive, every %s)", gate.desc, required, interval))

	warnAfter := c.GateWarnAfter
	if warnAfter <= 0 {
		warnAfter = 10 * time.Minute
	}
	started := time.Now()
	warned := false

	consecutive := 0
	// Several of ConfirmBoot's refusals are permanent for the rest of a boot (the
	// booted sha cannot change), so report on first occurrence and on change,
	// never once per tick.
	lastErr := ""
	// Reported on change, and never cleared on a healthy probe: an error that
	// comes and goes is already visible from its first report, and re-announcing
	// it every time it flaps would drown the log it is meant to inform.
	lastProbeErr := ""
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		healthy, err := prober.Healthy(ctx)
		switch {
		case err != nil:
			// A probe error is not evidence of ill health, but it is not evidence
			// of health either — reset, because "N consecutive" must mean N
			// consecutive PROVEN-healthy probes.
			consecutive = 0
			// Report it, on change only. The probers go to some trouble to
			// distinguish "the probe could not run" from "not ready yet" — a
			// missing systemctl, an unreachable endpoint — and discarding that
			// here threw the distinction away at the only place it could be
			// observed, leaving a gate that CANNOT be passed looking exactly like
			// a node that is merely slow to come up. Suppressed once ctx is done,
			// since a cancelled probe at shutdown is not a diagnosis.
			if ctx.Err() == nil {
				if msg := err.Error(); msg != lastProbeErr {
					lastProbeErr = msg
					c.onError("boot_confirm_probe", err)
				}
			}
		case healthy:
			consecutive++
		default:
			consecutive = 0
		}

		// Say so, once, when the gate has gone unpassed long enough that it is
		// more likely misconfigured than slow. Reported whether the probes are
		// failing or erroring, since a gate nobody can pass looks identical to a
		// node that is merely still coming up until you know how long it has been.
		if !warned && consecutive < required && time.Since(started) >= warnAfter {
			warned = true
			// Carry the last probe error, if any. Whether the gate is failing or
			// erroring is the first thing an operator needs and the one thing the
			// bare elapsed time cannot tell them.
			detail := ""
			if lastProbeErr != "" {
				detail = "; last probe error: " + lastProbeErr
			}
			c.onError("boot_confirm_gate", fmt.Errorf(
				"pending boot slot still unblessed after %s: health gate (%s) has reached only %d of "+
					"%d consecutive healthy probes; unless it passes, this image REVERTS on the next reboot%s",
				time.Since(started).Round(time.Second), gate.desc, consecutive, required, detail))
		}

		if consecutive >= required {
			if err := bootupgrade.ConfirmBoot(ctx, c.Runner, c.BootedGitSHA); err != nil {
				if msg := err.Error(); msg != lastErr {
					lastErr = msg
					c.onError("boot_confirm", err)
				}
				// Stay in the loop: a confirm can fail transiently (a busy ESP) and
				// ConfirmBoot leaves Pending set precisely so it is retried.
			} else {
				return nil
			}
		}

		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
		}
	}
}

// bootGate is the resolved health gate for this boot. desc exists so the
// unpassed-gate warning can name what was actually probed — the whole failure
// mode being that the gate was aimed somewhere the node could never satisfy.
type bootGate struct {
	prober   HealthProber
	desc     string
	required int
	interval time.Duration
}

func (c *BootConfirmer) resolveGate() bootGate {
	url := c.AppHealthURL
	required := c.RequiredConsecutive
	if required <= 0 {
		required = 3
	}
	interval := c.PollInterval
	if interval <= 0 {
		interval = 15 * time.Second
	}
	// The breadcrumb carries this boot's SiteSetting-delivered gate config, so
	// the gate can be retuned centrally with no new agent binary. It is also how
	// a hub declares its /up endpoint: an explicit URL from either source opts
	// the node into the HTTP probe, and absence of one is what selects the local
	// gate below.
	bc, err := LoadBreadcrumb(c.BreadcrumbPath)
	if err != nil {
		// Report it. This used to mean only "gate tuning falls back to defaults";
		// now it can change WHICH gate runs, silently demoting a node that had
		// been given a health endpoint down to the weaker local probe for the
		// rest of the boot.
		c.onError("boot_confirm_breadcrumb", err)
	}
	if err == nil && bc != nil {
		if bc.AppHealth.URL != "" {
			url = bc.AppHealth.URL
		}
		if bc.AppHealth.RequiredConsecutive > 0 {
			required = bc.AppHealth.RequiredConsecutive
		}
		if bc.AppHealth.PollIntervalSeconds > 0 {
			interval = time.Duration(bc.AppHealth.PollIntervalSeconds) * time.Second
		}
	}
	switch {
	case c.Prober != nil:
		return bootGate{c.Prober, "injected prober", required, interval}
	case url != "":
		return bootGate{newLoopbackProber(url, c.Hostname), "app health " + url, required, interval}
	case bc != nil && servesWebTier(bc.Modules):
		// This node composed the platform's web tier, so it can answer the
		// loopback probe — and being the platform, it is also the node where a
		// broken stack is least recoverable. Take the strong gate without waiting
		// to be told to, since on a self-hosted control plane nothing can tell it.
		return bootGate{
			newLoopbackProber(defaultAppHealthURL, c.Hostname),
			"app health " + defaultAppHealthURL + " (web tier detected in composed set)",
			required, interval,
		}
	default:
		// No app health endpoint, and this node does not serve one. Probe
		// something it can actually answer instead of a loopback URL only a hub
		// could serve — and require the agent's own reconcile to have completed,
		// because systemd alone cannot see the failure mode that matters here.
		return bootGate{newSystemdReadyProber(c.ReconcileOK), "systemd readiness + module reconcile", required, interval}
	}
}

func (c *BootConfirmer) onError(stage string, err error) {
	if c.OnError != nil {
		c.OnError(stage, err)
	}
}

// shortSHA trims a git sha for log lines; "" stays "" (unknown).
func shortSHA(s string) string {
	if len(s) > 12 {
		return s[:12]
	}
	return s
}
