package runtime

import (
	"context"
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
// The gate reuses the LKG capturer's prober and its SiteSetting-delivered
// AppHealthCfg (url / required_consecutive / poll_interval_seconds) carried on
// the boot breadcrumb, so both gates can be retuned centrally with no new agent
// binary, and a node cannot end up with the two disagreeing about what healthy
// means.
type BootConfirmer struct {
	// BreadcrumbPath supplies the AppHealthCfg override for this boot.
	BreadcrumbPath string
	// DefaultAppHealthURL is the loopback health URL when the breadcrumb carries
	// no override.
	DefaultAppHealthURL string
	// Hostname is the SNI/Host header for the loopback probe.
	Hostname string
	// BootedGitSHA identifies the image actually running, from /proc/cmdline.
	BootedGitSHA string
	// Runner performs the ESP mutations (bless / set-default).
	Runner mount.Runner
	// Prober overrides the health probe (tests).
	Prober HealthProber
	// RequiredConsecutive / PollInterval override the defaults (3 / 15s).
	RequiredConsecutive int
	PollInterval        time.Duration

	OnError func(stage string, err error)
}

// Run gates on health, then confirms. It returns once the boot is confirmed, or
// when ctx ends.
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

	prober, required, interval := c.resolveGate()

	consecutive := 0
	// Several of ConfirmBoot's refusals are permanent for the rest of a boot (the
	// booted sha cannot change), so report on first occurrence and on change,
	// never once per tick.
	lastErr := ""
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
		case healthy:
			consecutive++
		default:
			consecutive = 0
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

func (c *BootConfirmer) resolveGate() (HealthProber, int, time.Duration) {
	url := c.DefaultAppHealthURL
	required := c.RequiredConsecutive
	if required <= 0 {
		required = 3
	}
	interval := c.PollInterval
	if interval <= 0 {
		interval = 15 * time.Second
	}
	// The breadcrumb carries this boot's SiteSetting-delivered gate config; the
	// LKG capturer reads the same fields, so the two gates stay in agreement.
	if bc, err := LoadBreadcrumb(c.BreadcrumbPath); err == nil && bc != nil {
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
	prober := c.Prober
	if prober == nil {
		prober = newLoopbackProber(url, c.Hostname)
	}
	return prober, required, interval
}

func (c *BootConfirmer) onError(stage string, err error) {
	if c.OnError != nil {
		c.OnError(stage, err)
	}
}
