package runtime

// One-shot, app-health-gated capture of the frozen boot-LKG (Level 1, #39).
//
// The capturer runs as its own goroutine in the service (post-pivot). It exists
// solely to promote the CURRENT boot's breadcrumb (what ComposeForPivot actually
// composed) to the frozen last-known-good — and ONLY after the COMPOSED control
// plane passes an application-level health check.
//
// Why app-level (composed /up 200), not the agent heartbeat: the agent lives in
// base-os and heartbeats regardless of whether the composed hub-backend is
// healthy. A hub-backend that boots-but-500s would falsely "confirm" on agent
// liveness. The gate must probe the composed app actually serving.
//
// Why the breadcrumb, not the live reconcile state: a hot-mounted new module
// version's erofs is on disk, but the running code is still the OLD version
// until a future reboot (hot-mount != code-active). Promoting the live/
// hot-reconciled set would certify an unproven composition against still-running
// old code and brick the next cold boot. Promoting the breadcrumb — the set THIS
// boot cold-composed and is now serving — guarantees the LKG is always a
// proven-cold-boots-healthy composition.
//
// One-shot + frozen: the capturer promotes at most once per boot and never
// overwrites an existing frozen LKG. Re-provisioning (to capture a newer desired
// composition before a decommission) is a deliberate operator action that
// removes the LKG file so the next app-health-confirmed boot recaptures.

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"net/http"
	"os"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/fsutil"
)

// HealthProber reports whether the composed control plane is serving. Injected
// so tests can drive the gate deterministically.
type HealthProber interface {
	Healthy(ctx context.Context) (bool, error)
}

// HTTPHealthProber probes the composed control plane's health endpoint and
// treats a 2xx as healthy. It carries the node's mTLS identity (Client) so the
// probe passes the host-login ingress if that endpoint is mTLS-gated; HostHeader
// lets it target a loopback IP while presenting the node's SNI/Host.
type HTTPHealthProber struct {
	URL        string
	HostHeader string
	Client     *http.Client
	Timeout    time.Duration
}

// Healthy issues one GET and reports 2xx.
func (p *HTTPHealthProber) Healthy(ctx context.Context) (bool, error) {
	if p.URL == "" {
		return false, errors.New("health prober: empty URL")
	}
	timeout := p.Timeout
	if timeout <= 0 {
		timeout = 5 * time.Second
	}
	cctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(cctx, http.MethodGet, p.URL, nil)
	if err != nil {
		return false, err
	}
	if p.HostHeader != "" {
		req.Host = p.HostHeader
	}
	client := p.Client
	if client == nil {
		// Loopback self-probe default: skip cert-name verification (we only care
		// that the composed app answers 200; the SNI cert is the node's own).
		client = &http.Client{
			Timeout:   timeout,
			Transport: &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}}, //nolint:gosec // loopback self-probe
		}
	}
	resp, err := client.Do(req)
	if err != nil {
		return false, err
	}
	defer resp.Body.Close()
	return resp.StatusCode >= 200 && resp.StatusCode < 300, nil
}

// LKGCapturer promotes the boot breadcrumb to the frozen LKG once the composed
// app is health-confirmed.
type LKGCapturer struct {
	// Prober, when set, overrides the config-built prober (tests inject a stub).
	Prober         HealthProber
	BreadcrumbPath string
	LKGPath        string
	// DefaultAppHealthURL is the loopback health URL used when the breadcrumb
	// carries no SiteSetting-delivered override.
	DefaultAppHealthURL string
	// Hostname is the SNI/Host header for the loopback probe.
	Hostname string
	// CachePath maps a digest to its erofs blob path (mount.Layout.ModuleCachePath)
	// for the capture-time blob-presence belt; nil skips it (tests).
	CachePath func(digest string) string
	// RequiredConsecutive healthy probes before promotion (default 3) — a
	// short window that avoids capturing on a single flapping 200. Overridden by
	// the breadcrumb's SiteSetting-delivered value when >0.
	RequiredConsecutive int
	// PollInterval between probes (default 15s). Overridden by the breadcrumb's
	// SiteSetting-delivered value when >0.
	PollInterval time.Duration
	Now          func() time.Time
	OnError      func(stage string, err error)
}

// resolveGate reads the SiteSetting-delivered promotion-gate config (probe URL +
// required-consecutive + poll interval) from THIS boot's breadcrumb snapshot,
// falling back to the capturer's compile-time defaults. Returns the prober to
// use (an injected Prober always wins, for tests) plus the resolved N + interval.
// This is what lets the gate be strengthened (e.g. /up → a composed-API check,
// or a longer window) centrally, with NO new agent binary.
func (c *LKGCapturer) resolveGate(bc *BootComposedBreadcrumb) (HealthProber, int, time.Duration) {
	url := c.DefaultAppHealthURL
	required := c.required()
	interval := c.interval()
	if bc != nil {
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

// newLoopbackProber builds the shared self-probe used by every health gate on
// the node (LKG capture and boot-slot bless). The health client is built ONCE
// per gate and reused across probes: a fresh http.Client/Transport per probe
// would leak idle connections + FDs on a never-healthy node, where a gate can
// probe for the whole life of the boot. IdleConnTimeout reaps idle keep-alives.
// TLS verification is skipped because this is a loopback probe of the node's own
// ingress, which legitimately presents a cert for its public name.
func newLoopbackProber(url, hostname string) HealthProber {
	return &HTTPHealthProber{
		URL:        url,
		HostHeader: hostname,
		Timeout:    5 * time.Second,
		Client: &http.Client{
			Timeout: 5 * time.Second,
			Transport: &http.Transport{
				TLSClientConfig: &tls.Config{InsecureSkipVerify: true}, //nolint:gosec // loopback self-probe
				IdleConnTimeout: 30 * time.Second,
			},
		},
	}
}

func (c *LKGCapturer) required() int {
	if c.RequiredConsecutive > 0 {
		return c.RequiredConsecutive
	}
	return 3
}

func (c *LKGCapturer) interval() time.Duration {
	if c.PollInterval > 0 {
		return c.PollInterval
	}
	return 15 * time.Second
}

func (c *LKGCapturer) now() time.Time {
	if c.Now != nil {
		return c.Now()
	}
	return time.Now().UTC()
}

func (c *LKGCapturer) onError(stage string, err error) {
	if c.OnError != nil && err != nil {
		c.OnError(stage, err)
	}
}

// Run blocks until it promotes an LKG, determines there is nothing to do, or ctx
// is canceled. Returns nil on a clean exit (promoted / already-frozen / ctx
// done); it never propagates a fatal error — capture is best-effort and its
// failure must never take down the service.
func (c *LKGCapturer) Run(ctx context.Context) error {
	// A present-but-unreadable LKG is left alone for the operator rather than
	// clobbered. Checked first because it is a refusal, not a decision about
	// what this boot composed.
	frozenExists := false
	if existing, err := LoadBootLKG(c.LKGPath); err == nil {
		frozenExists = existing.Frozen
	} else if !errors.Is(err, os.ErrNotExist) {
		c.onError("lkg_capture:load_existing", err)
		return nil
	}

	// Snapshot THIS boot's breadcrumb ONCE, at entry, and promote this in-memory
	// copy — never a re-read at promotion time. This makes correction-#1
	// structural across the ENTIRE pre-freeze window: even if something rewrote
	// the on-disk breadcrumb after boot, the capturer freezes the set THIS boot
	// actually cold-composed. (Today nothing else writes the breadcrumb, but
	// "safe by absence" would silently break the instant a future post-boot
	// writer appeared.)
	bc, err := LoadBreadcrumb(c.BreadcrumbPath)
	if err != nil {
		// No breadcrumb (compose wrote none, e.g. its best-effort write failed)
		// → nothing proven to promote; don't run the gate.
		c.onError("lkg_capture:no_breadcrumb", err)
		return nil
	}
	// Refuse a breadcrumb that did not come from THIS boot. The breadcrumb write
	// is best-effort, so a failed write leaves the previous boot's file in place —
	// and since FromPending can now authorise overwriting a proven LKG, a stale
	// one could promote a set that already failed its trial. Empty on either side
	// means the id is unavailable (non-Linux, /proc absent), where we keep the
	// prior behaviour rather than refusing to capture at all.
	nowBoot := CurrentBootID()
	if nowBoot != "" && bc.BootID != "" && bc.BootID != nowBoot {
		c.onError("lkg_capture:stale_breadcrumb", fmt.Errorf(
			"breadcrumb is from boot %s but this is boot %s — refusing to promote a set this boot did not compose",
			bc.BootID, nowBoot))
		return nil
	}
	// Proceeding without id verification is deliberate: refusing would let any
	// future sandbox that hides /proc permanently and silently disable LKG
	// advancement — the same failure SHAPE this mechanism exists to remove. But a
	// FromPending promotion is the one case where staleness could overwrite a
	// proven LKG, so say so out loud rather than degrading quietly. Also covers
	// the one-boot transition window after an agent upgrade, where the previous
	// binary wrote a breadcrumb with no BootID at all.
	if bc.FromPending && (nowBoot == "" || bc.BootID == "") {
		c.onError("lkg_capture:unverified_pending_promotion", fmt.Errorf(
			"promoting a staged set without boot-id verification (breadcrumb id %q, current %q) — "+
				"a breadcrumb left by a previous boot could not be distinguished from this one",
			bc.BootID, nowBoot))
	}
	if bc.FromLKG {
		return nil // this boot fell back to the LKG — nothing new to promote
	}
	// The frozen-LKG bail lives HERE, below the breadcrumb read, precisely because
	// it must NOT apply to a FromPending boot. It used to sit above, before the
	// breadcrumb existed — which made the whole promotion path unreachable on the
	// nodes this mechanism was built for: a self-hosted control plane always has a
	// frozen LKG (that is the premise), so the capturer returned before it could
	// ever see that this boot had composed something new. Ordinary boots still
	// never overwrite a frozen floor.
	if frozenExists && !bc.FromPending {
		return nil
	}
	if bc.Incomplete {
		// Degraded boot (a data module was dropped at compose) — never freeze an
		// incomplete set as last-known-good. Surfaces via the arm-telemetry
		// (the LKG's confirmed_at won't advance).
		c.onError("lkg_capture:incomplete_boot",
			errors.New("this boot composed an INCOMPLETE assigned set — skipping LKG capture"))
		return nil
	}

	prober, required, interval := c.resolveGate(bc)
	consecutive := 0
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		healthy, err := prober.Healthy(ctx)
		if err != nil {
			c.onError("lkg_capture:probe", err)
			consecutive = 0
		} else if healthy {
			consecutive++
		} else {
			consecutive = 0
		}

		if consecutive >= required {
			if err := c.promote(bc); err != nil {
				c.onError("lkg_capture:promote", err)
				return nil
			}
			// The staged set has now proven healthy and IS the frozen LKG; drop it
			// so a later boot does not burn attempts re-trying what it already is.
			// Best-effort: a leftover file is harmless (its checksum still matches
			// the LKG) and it expires by attempt count regardless.
			if bc.FromPending {
				if err := ClearPendingCompose(PendingComposePath); err != nil {
					c.onError("lkg_capture:clear_pending", err)
				}
			}
			return nil
		}

		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
		}
	}
}

// promote writes the ENTRY-SNAPSHOT breadcrumb (bc, captured at Run() entry) as
// the frozen LKG. Re-checks for an existing frozen LKG immediately before writing
// (belt: never overwrite one). Promotes the snapshot VERBATIM — never a re-read
// of the on-disk breadcrumb and never the live/hot-reconciled mount state.
func (c *LKGCapturer) promote(bc *BootComposedBreadcrumb) error {
	// A frozen LKG is normally never overwritten — it is the proven floor, and a
	// later boot has nothing better to offer. The ONE exception is a boot that
	// composed from a STAGED set and then proved healthy: that is strictly newer
	// evidence about a strictly newer set, and promoting it is the only mechanism
	// by which a self-hosted control plane's LKG can ever advance (its pre-pivot
	// fetch can never succeed, so without this the frozen set is permanent).
	if existing, err := LoadBootLKG(c.LKGPath); err == nil && existing.Frozen && !bc.FromPending {
		return nil // already captured (or re-provision raced) — do not overwrite
	}
	if bc == nil {
		return errors.New("promote: nil breadcrumb snapshot")
	}
	// Overwriting a proven LKG leaves nothing beneath the new one. The kernel A/B
	// always keeps the previous slot as the floor below the payload; the module
	// rung has no equivalent, so a gate-passing-but-degraded set would become the
	// only floor. Keep one generation back. Best-effort: failing to copy must not
	// block a promotion that is otherwise correct.
	if bc.FromPending {
		if prev, rerr := os.ReadFile(c.LKGPath); rerr == nil {
			if werr := fsutil.AtomicWrite(c.LKGPath+".prev", prev, 0o644); werr != nil {
				c.onError("lkg_capture:keep_previous", werr)
			}
		}
	}
	if bc.FromLKG {
		// This boot itself fell back to the LKG — nothing new to promote (Run()
		// already returns before the gate on this, but keep the guard).
		return nil
	}
	if len(bc.Modules) == 0 {
		return errors.New("breadcrumb has no modules — refusing to promote an empty LKG")
	}
	// Capture-time belt: the breadcrumb records THIS boot's composed set; verify
	// each data module's blob is actually present in the digest-keyed cache
	// before freezing, so the LKG is valid the instant it is written (never a
	// frozen snapshot pointing at a blob that isn't there). This validates the
	// breadcrumb against what's actually on disk — NOT against the live
	// AttachedModules mount state, which a post-boot hot-reconcile may already
	// have drifted (validating against that would re-open the poison).
	if c.CachePath != nil {
		for _, m := range bc.Modules {
			if !m.HasDataFile {
				continue
			}
			if m.Digest == "" {
				return fmt.Errorf("breadcrumb module %s has_data_file but no digest", m.ID)
			}
			if _, err := os.Stat(c.CachePath(m.Digest)); err != nil {
				return fmt.Errorf("breadcrumb module %s blob absent at capture: %w", m.ID, err)
			}
		}
	}
	lkg := &BootLKG{
		ConfirmedAt:               c.now(),
		Source:                    bc.Source,
		NodeID:                    bc.NodeID,
		Hostname:                  bc.Hostname,
		StalenessThresholdSeconds: bc.StalenessThresholdSeconds,
		AppHealth:                 bc.AppHealth,
		Modules:                   bc.Modules,
	}
	return WriteBootLKG(c.LKGPath, lkg)
}
