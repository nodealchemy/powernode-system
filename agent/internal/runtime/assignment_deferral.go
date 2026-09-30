package runtime

import (
	"sort"
	"time"
)

// The two conditions in which the reconciler keeps a module it would otherwise
// have detached, or skips a render, because the platform's answer cannot be
// trusted (IMP-1023e79cc82d). Both are safe and both are silent unless somebody
// is told: a node stuck in either one runs a composition that no longer matches
// what the platform assigned, forever.
const (
	// DeferralEmptyAssignment: the assignment list named no data-bearing module
	// while modules were attached and not confirmed unassigned, so their detach
	// was deferred (filterEmptyAssignmentDetaches).
	DeferralEmptyAssignment = "empty_assignment"
	// DeferralIdentityRenderSkipped: an attached or boot-composed module's
	// manifest could not be resolved, so the /etc/passwd + sudoers + egress
	// render (and the attach/reattach that depends on it) was skipped this tick.
	DeferralIdentityRenderSkipped = "identity_render_skipped"
)

// AssignmentDeferralReport is one live deferral condition, as carried on the
// heartbeat (HeartbeatPayload.AssignmentDeferral). PersistedSeconds is the age of
// the unbroken run of this same condition, measured on the agent's own clock as
// a DURATION, so the platform never compares two machines' wall clocks.
type AssignmentDeferralReport struct {
	Reason           string   `json:"reason"`
	ModuleIDs        []string `json:"module_ids,omitempty"`
	PersistedSeconds int64    `json:"persisted_seconds"`
}

// recordAssignmentDeferral notes, for THIS pass, that reason is in force for the
// named modules. Called from RunOnce's own goroutine with r.mu held, so the
// pending map needs no lock of its own; nothing is visible to the heartbeat until
// publishAssignmentDeferral.
func (r *Reconciler) recordAssignmentDeferral(reason string, moduleIDs []string) {
	if len(moduleIDs) == 0 {
		return
	}
	if r.deferralPending == nil {
		r.deferralPending = map[string][]string{}
	}
	r.deferralPending[reason] = append(r.deferralPending[reason], moduleIDs...)
}

// resetAssignmentDeferralPending starts a pass with nothing pending. It does NOT
// touch the published value: a pass that fails before it can decide (a fetch
// error) must leave the previous verdict standing rather than read as "cleared".
func (r *Reconciler) resetAssignmentDeferralPending() {
	r.deferralPending = nil
}

// publishAssignmentDeferral swaps the published deferral set to this pass's, in
// ONE atomic store (same reason as publishSecurityFailClosed: mu is held for the
// whole pass, so the heartbeat goroutine reads the atomic and must only ever see
// a complete verdict). Called once per pass, at the point the pass has decided
// both the detach set and whether the render is skipped. A reason that is absent
// this pass drops its start time, so its next occurrence counts from zero.
func (r *Reconciler) publishAssignmentDeferral() {
	now := r.nowUnixOrTime()
	if r.deferralSince == nil {
		r.deferralSince = map[string]int64{}
	}
	reasons := make([]string, 0, len(r.deferralPending))
	for reason := range r.deferralPending {
		reasons = append(reasons, reason)
	}
	sort.Strings(reasons)
	for reason := range r.deferralSince {
		if _, live := r.deferralPending[reason]; !live {
			delete(r.deferralSince, reason)
		}
	}

	reports := make([]AssignmentDeferralReport, 0, len(reasons))
	for _, reason := range reasons {
		since, ok := r.deferralSince[reason]
		if !ok {
			since = now
			r.deferralSince[reason] = since
		}
		ids := uniqueSorted(r.deferralPending[reason])
		reports = append(reports, AssignmentDeferralReport{Reason: reason, ModuleIDs: ids, PersistedSeconds: now - since})
	}
	r.assignmentDeferral.Store(&reports)
}

// AssignmentDeferral returns the deferral conditions the last decided pass left
// in force, or nil when there are none. Safe from any goroutine.
func (r *Reconciler) AssignmentDeferral() []AssignmentDeferralReport {
	p := r.assignmentDeferral.Load()
	if p == nil || len(*p) == 0 {
		return nil
	}
	out := make([]AssignmentDeferralReport, len(*p))
	for i, rep := range *p {
		rep.ModuleIDs = append([]string(nil), rep.ModuleIDs...)
		out[i] = rep
	}
	return out
}

func (r *Reconciler) nowUnixOrTime() int64 {
	if r.nowUnix != nil {
		return r.nowUnix()
	}
	return time.Now().Unix()
}

func uniqueSorted(in []string) []string {
	seen := make(map[string]bool, len(in))
	out := make([]string, 0, len(in))
	for _, s := range in {
		if s != "" && !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	sort.Strings(out)
	return out
}
