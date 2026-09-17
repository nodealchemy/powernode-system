// Package signingaudit collects the module-signing ladder's findings on the
// node so they can ride the heartbeat to the platform (IMP-c52b5c2d6cbf).
//
// The audit rungs exist to measure what an enforcing rung would refuse:
// verify.AuditVerifier reports `verify:module_signature_audit` and
// verify.AuditDigestVerifier reports `verify:module_fsverity_audit`, each
// naming a blob the enforcing mode would have refused. Both deliver through the
// site's report hook, and in production that hook writes to os.Stderr — the
// service's journal, or the initramfs console for the boot composer. Nothing
// reached the platform, so "run audit until the fleet is quiet" meant reading
// every node's journal by hand, which is why the ladder's default stayed `off`.
//
// This collector is a TEE, never a replacement: the stderr hook keeps receiving
// every report. What it adds is a bounded, de-duplicated summary the heartbeat
// can carry.
//
// ABSENCE IS THE POINT, NOT PRESENCE. Enforcing is justified by finding
// NOTHING, so "audit ran here and this node is quiet" has to reach the platform
// as a positive measurement. That is what MarkActive is for: a collector that
// was never marked active snapshots as nil (signing `off` — NOT MEASURED),
// while an active one with no findings snapshots as a present, empty
// Observation (QUIET). Collapsing those two is the defect this package exists
// to avoid: it would leave an operator unable to tell a measured-clean fleet
// from one that never measured, which is exactly where the task found them.
//
// DE-DUPLICATION IS WHY IT IS BOUNDED. The same finding repeats constantly: a
// failing attach is retried every reconcile tick, and the fs-verity arm checks a
// newly attached module twice per tick (prefetch and attach). One row per report
// would ship an unbounded, mostly identical list every 30 seconds. One row per
// DISTINCT finding, with a count and a first/last timestamp, is the same
// information at a fixed size.
package signingaudit

import (
	"strings"
	"sync"
	"time"
)

// DefaultMaxFindings bounds the distinct findings a node reports. A node whose
// entire module set is unsigned produces one finding per blob; the cap keeps a
// misconfigured node from turning its heartbeat into an upload.
const DefaultMaxFindings = 32

// MaxDetailChars bounds one finding's detail. The text is an error string that
// can embed a path and a command's output, and it crosses to a read surface on
// the platform.
const MaxDetailChars = 300

// Stages this collector accepts.
//
// The first two are the audit rungs themselves. The second two are the
// MEASUREMENT'S OWN FAILURE MODES, and they matter just as much: a non-
// enforcing site with no trust anchor degrades to verify.AlwaysOK and reports
// StageSigningDegraded, which means the node is configured for audit and is
// verifying NOTHING. Dropping that would let such a node report zero findings —
// a positive claim of QUIET from a node that measured nothing, delivered
// precisely when the operator is deciding whether to enforce.
//
// Every OTHER stage the agent reports (compose:*, hostname_apply, a2a, …) is a
// different measurement with a different reader; folding those in would make
// the platform's signing document mean "any agent error" and quietly break the
// one question it exists to answer.
const (
	StageSignature       = "verify:module_signature_audit"
	StageFsverity        = "verify:module_fsverity_audit"
	StageSigningDegraded = "verify:module_signing"
	StageSigningKeys     = "verify:module_signing_keys"
)

// Finding is one distinct observation, as it appears on the wire.
type Finding struct {
	Stage  string `json:"stage"`
	Detail string `json:"detail"`
	// Count is how many times this exact finding was reported since the agent
	// started. It never resets on a heartbeat: the platform reads a rising
	// count as "still happening", and a frozen one as "not seen again". It
	// DOES reset when the agent restarts, so a falling count means "this agent
	// is younger than the last report", not "the finding cleared" — the
	// heartbeat's boot_id is what distinguishes the two.
	Count     int    `json:"count"`
	FirstSeen string `json:"first_seen"`
	LastSeen  string `json:"last_seen"`
}

// Observation is the block the heartbeat carries: the findings, the ladder rung
// that produced them, and whether the cap dropped any.
//
// MODE IS LOAD-BEARING, not decoration. What an empty findings list PROVES
// depends entirely on the rung, because the arms reporting into it differ:
//
//	audit           — both arms report. Empty means the signature arm and the
//	                  fs-verity arm both ran and found nothing.
//	runtime / all   — the signature arm ENFORCES at this site (see
//	                  verify.ModuleSigningConfig.Enforces) and constructs no
//	                  AuditVerifier, so it contributes NOTHING here. Empty
//	                  means only that the fs-verity arm is quiet.
//
// Without this field a `runtime` node is indistinguishable from an audited,
// verified-clean one, and an operator reading it as the go-signal for `all` —
// the rung that makes an unsigned module an unbootable node — would be acting
// on evidence the document never carried. Same failure as reading an absent
// block as "clean", one rung up.
//
// Truncated rides the wire because without it finding_count reads as "this
// node's problems" when it is only the size of this window — an operator
// backfilling the named blobs would never learn how many went unnamed.
type Observation struct {
	Mode      string    `json:"mode"`
	Findings  []Finding `json:"findings"`
	Truncated bool      `json:"truncated"`
}

// Collector is safe for concurrent use: the reconciler goroutine reports while
// the heartbeat goroutine snapshots.
type Collector struct {
	mu        sync.Mutex
	max       int
	active    bool
	mode      string
	order     []string // insertion order, so the snapshot is stable
	findings  map[string]*Finding
	truncated bool
	now       func() time.Time
}

// New returns a collector bounded to max distinct findings. A non-positive max
// falls back to DefaultMaxFindings rather than collecting nothing, because a
// zero cap would silently disable the measurement.
func New(max int) *Collector {
	if max <= 0 {
		max = DefaultMaxFindings
	}
	return &Collector{max: max, findings: make(map[string]*Finding), now: time.Now}
}

// MarkActive records that a verification pass actually runs on this node, so an
// empty result is a MEASUREMENT (quiet) rather than an ABSENCE (never ran). The
// caller marks it only when the operator's policy is active — see
// verify.ModuleSigningConfig.Active — and passes the rung, because which arms
// report into this block depends on it (see Observation). Nil-receiver safe.
func (c *Collector) MarkActive(mode string) {
	if c == nil {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.active = true
	c.mode = strings.ToLower(strings.TrimSpace(mode))
}

// Report is the hook shape the verify package's Report field expects. A nil
// receiver is a no-op so a construction site that never built a collector needs
// no guard of its own.
func (c *Collector) Report(stage string, err error) {
	if c == nil || err == nil || !accepted(stage) {
		return
	}

	detail := truncate(err.Error(), MaxDetailChars)
	key := stage + "\x00" + detail
	stamp := c.now().UTC().Format(time.RFC3339)

	c.mu.Lock()
	defer c.mu.Unlock()

	if f, ok := c.findings[key]; ok {
		f.Count++
		f.LastSeen = stamp
		return
	}
	// The cap drops NEW distinct findings. Known ones keep counting above, so a
	// full collector still reports that the findings it holds are ongoing.
	if len(c.findings) >= c.max {
		c.truncated = true
		return
	}
	c.findings[key] = &Finding{Stage: stage, Detail: detail, Count: 1, FirstSeen: stamp, LastSeen: stamp}
	c.order = append(c.order, key)
}

// Tee returns a report hook that feeds this collector AND the hook the call
// site already had (the stderr writer, in production). inner may be nil.
func (c *Collector) Tee(inner func(string, error)) func(string, error) {
	return func(stage string, err error) {
		c.Report(stage, err)
		if inner != nil {
			inner(stage, err)
		}
	}
}

// Snapshot is the heartbeat's view.
//
//	nil                      — NOT MEASURED. No verification pass runs here
//	                           (signing `off`) and nothing was reported, so the
//	                           heartbeat omits the key and the platform keeps
//	                           whatever document it had. It must never read as
//	                           "clean".
//	Findings empty, non-nil  — QUIET. A pass runs and has nothing to report.
//	                           This is the fact the ladder waits for before
//	                           enforcing, so it is a measurement, not silence.
//	Findings present         — what enforcing would refuse here, today.
//
// A reported finding is always returned, marked active or not: dropping a real
// finding because a wiring step was missed would hide the very thing this block
// carries.
func (c *Collector) Snapshot() *Observation {
	if c == nil {
		return nil
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.active && len(c.order) == 0 {
		return nil
	}
	out := make([]Finding, 0, len(c.order))
	for _, key := range c.order {
		out = append(out, *c.findings[key])
	}
	return &Observation{Mode: c.mode, Findings: out, Truncated: c.truncated}
}

func accepted(stage string) bool {
	switch stage {
	case StageSignature, StageFsverity, StageSigningDegraded, StageSigningKeys:
		return true
	}
	return false
}

func truncate(s string, max int) string {
	s = strings.TrimSpace(s)
	if len(s) <= max {
		return s
	}
	return s[:max] + "…"
}
