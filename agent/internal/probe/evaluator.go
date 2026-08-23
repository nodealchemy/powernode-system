package probe

import (
	"context"
	"sort"
	"sync"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// DefaultRefreshInterval is how often a module whose digest has NOT changed is
// re-probed. Every probe costs two subshells, and heartbeats run every ~30s,
// so re-running on each beat would be pure waste on a steady fleet. A CHANGED
// digest bypasses this entirely (see Refresh) — a fresh deploy is exactly the
// moment the answer matters, and waiting out an interval to learn a deploy
// broke the node is the opposite of the point.
const DefaultRefreshInterval = 10 * time.Minute

// DefaultRefreshBudget bounds ONE Refresh pass end to end.
//
// This is load-bearing, not hygiene. Refresh is called from the heartbeat
// loop's PostSend, which runs SYNCHRONOUSLY between one heartbeat and the
// next (runtime/heartbeat.go: PostSend() then the interval wait). So an
// unbudgeted pass delays the next heartbeat by its own duration — and with a
// per-shell timeout of 10s, a 32-probe module could stall it for over ten
// minutes, past the platform's 600s live-heartbeat window. The node would go
// SILENT, which is an outage manufactured by an observability feature.
//
// A budget rather than a goroutine: a background refresh would let passes
// overlap on a slow host and would need its own serialization, for no gain —
// the work is already skipped entirely on a steady fleet.
//
// Exceeding it is not an error. The pass stops where it is, whatever it
// already stored stands, and the modules it did not reach keep their previous
// (or absent) report — which the platform ages out on the agent's own clock
// and reads as NOT MEASURED, never as a pass.
const DefaultRefreshBudget = 20 * time.Second

// Evaluator owns the node's verify-probe state.
//
// It is snapshot-style, like sdwan.Manager: Refresh runs the probes and stores
// the result; Snapshot hands the stored result to the heartbeat builder under
// a mutex. The two are deliberately separate loops. Probing spawns subshells,
// and a heartbeat that blocked on them would make a slow or wedged filesystem
// look like a silent node — turning an observability feature into an outage.
//
// Consequence the server is built to handle: a wedged Refresh keeps re-shipping
// the SAME snapshot every beat, which the platform would otherwise re-stamp as
// fresh. That is why each ModuleReport carries its own ObservedAt (the AGENT's
// clock, written only at the end of a completed run) and why the sensor keys
// staleness on it rather than on ingest time.
type Evaluator struct {
	Runner Runner
	Root   string // manifest cache root; defaults to manifest.DefaultRoot
	// StatePath is the agent's attach-state file. A FIELD, not the
	// mount.StatePath constant read inline: a const path here would make
	// every test of this package read — and any future write-side change
	// mutate — the LIVE /persist state of whatever host the suite runs on.
	// Defaults to mount.StatePath when empty.
	StatePath string
	Interval  time.Duration // defaults to DefaultRefreshInterval
	Timeout   time.Duration // PER SHELL invocation; defaults to DefaultTimeout
	Budget    time.Duration // whole-pass ceiling; defaults to DefaultRefreshBudget
	OnError   func(stage string, err error)

	mu       sync.Mutex
	reports  map[string]ModuleReport // module id -> last report
	digests  map[string]string       // module id -> digest the report was taken at
	probedAt map[string]time.Time
}

// NewEvaluator builds an Evaluator with production defaults.
func NewEvaluator(onError func(string, error)) *Evaluator {
	if onError == nil {
		onError = func(string, error) {}
	}
	return &Evaluator{
		Runner:    ExecRunner{},
		Root:      manifest.DefaultRoot,
		StatePath: mount.StatePath,
		Interval:  DefaultRefreshInterval,
		Timeout:   DefaultTimeout,
		Budget:    DefaultRefreshBudget,
		OnError:   onError,
		reports:   map[string]ModuleReport{},
		digests:   map[string]string{},
		probedAt:  map[string]time.Time{},
	}
}

// Refresh probes every attached module that declares a `verify:` block, and
// drops the state of modules that are no longer attached.
//
// Safe to call on every heartbeat: a module whose digest is unchanged and
// whose last run is younger than Interval is skipped, so a steady fleet does
// no work at all. Bounded by Budget end to end — see DefaultRefreshBudget for
// why that bound is what keeps this off the heartbeat's critical path in the
// only sense that matters. Never returns an error: a run that cannot happen
// is reported through OnError and leaves the previous snapshot in place,
// which the server ages out on ObservedAt rather than mistaking for current.
func (e *Evaluator) Refresh(ctx context.Context) {
	if e == nil {
		return
	}
	if e.budget() > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, e.budget())
		defer cancel()
	}
	st, err := mount.LoadState(e.statePath())
	if err != nil {
		e.onError("probe_load_state", err)
		return
	}

	attached := map[string]string{}
	for _, m := range st.AttachedModules {
		attached[m.ID] = m.Digest
	}
	e.prune(attached)

	// Stable order so a budget exhaustion does not starve the same module
	// every pass — an unordered map walk would make "which modules got
	// probed" depend on Go's map randomization.
	ids := make([]string, 0, len(attached))
	for id := range attached {
		ids = append(ids, id)
	}
	sort.Strings(ids)

	for _, id := range ids {
		// The budget's only enforcement point. Checked BEFORE starting a
		// module rather than relied on mid-probe, so a pass never leaves a
		// module half-reported.
		if ctx.Err() != nil {
			e.onError("probe_refresh_budget", ctx.Err())
			return
		}
		digest := attached[id]
		if !e.due(id, digest) {
			continue
		}
		man, err := manifest.LoadFromDisk(e.root(), id)
		if err != nil {
			// No cached manifest means we cannot know what this module
			// declares. Recording nothing is correct: the server reads a
			// missing module report as NOT MEASURED, never as verified.
			e.onError("probe_load_manifest", err)
			continue
		}
		probes := FromConfig(man.Config)
		if len(probes) == 0 {
			// Declares nothing to prove. Clear any stale report so a module
			// that DROPPED its verify: block stops reporting an old verdict.
			e.forget(id)
			continue
		}
		e.store(id, digest, RunModuleWithTimeout(ctx, e.runner(), id, man.Name, probes, e.timeout()))
	}
}

// Snapshot is the heartbeat's view: a stable-ordered copy of the stored
// reports. Nil when nothing on this node declares a probe, so the heartbeat
// omits the key entirely and the platform records an ABSENCE rather than an
// empty-but-present block it might read as "nothing failed".
func (e *Evaluator) Snapshot() []ModuleReport {
	if e == nil {
		return nil
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if len(e.reports) == 0 {
		return nil
	}
	out := make([]ModuleReport, 0, len(e.reports))
	for _, r := range e.reports {
		out = append(out, r)
	}
	SortReports(out)
	return out
}

func (e *Evaluator) due(id, digest string) bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	// A digest change is a NEW artifact on this node. Re-probe immediately,
	// interval be damned — this is the moment a bad publish is detectable.
	if e.digests[id] != digest {
		return true
	}
	last, ok := e.probedAt[id]
	if !ok {
		return true
	}
	return time.Since(last) >= e.interval()
}

func (e *Evaluator) store(id, digest string, report ModuleReport) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.ensure()
	e.reports[id] = report
	e.digests[id] = digest
	e.probedAt[id] = time.Now()
}

func (e *Evaluator) forget(id string) {
	e.mu.Lock()
	defer e.mu.Unlock()
	delete(e.reports, id)
	delete(e.digests, id)
	delete(e.probedAt, id)
}

// prune drops state for modules that are no longer attached. Without it a
// detached module keeps reporting its last verdict forever — including a PASS
// for a capability the node no longer carries.
func (e *Evaluator) prune(attached map[string]string) {
	e.mu.Lock()
	defer e.mu.Unlock()
	for id := range e.reports {
		if _, ok := attached[id]; !ok {
			delete(e.reports, id)
			delete(e.digests, id)
			delete(e.probedAt, id)
		}
	}
}

func (e *Evaluator) ensure() {
	if e.reports == nil {
		e.reports = map[string]ModuleReport{}
	}
	if e.digests == nil {
		e.digests = map[string]string{}
	}
	if e.probedAt == nil {
		e.probedAt = map[string]time.Time{}
	}
}

func (e *Evaluator) runner() Runner {
	if e.Runner == nil {
		return ExecRunner{}
	}
	return e.Runner
}

func (e *Evaluator) statePath() string {
	if e.StatePath == "" {
		return mount.StatePath
	}
	return e.StatePath
}

func (e *Evaluator) root() string {
	if e.Root == "" {
		return manifest.DefaultRoot
	}
	return e.Root
}

func (e *Evaluator) interval() time.Duration {
	if e.Interval <= 0 {
		return DefaultRefreshInterval
	}
	return e.Interval
}

func (e *Evaluator) timeout() time.Duration {
	if e.Timeout <= 0 {
		return DefaultTimeout
	}
	return e.Timeout
}

func (e *Evaluator) budget() time.Duration {
	if e.Budget <= 0 {
		return DefaultRefreshBudget
	}
	return e.Budget
}

func (e *Evaluator) onError(stage string, err error) {
	if e.OnError != nil {
		e.OnError(stage, err)
	}
}
