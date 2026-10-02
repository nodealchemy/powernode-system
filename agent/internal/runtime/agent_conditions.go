package runtime

import (
	"errors"
	"fmt"
	"sort"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/etcsudoers"
)

// Condition kinds carried on the heartbeat (HeartbeatPayload.AgentConditions).
//
// The agent has conditions an operator must know about that are deliberately NOT
// failures of the pass: a known-degraded unit must not become a convergence
// failure (that would fail every apply_config forever, see
// reportKnownDegradedUnits), and a refused sudoers grant is one module's own
// defect that must not stall other modules' upgrades. Both used to reach only
// cfg.OnError, i.e. stderr and the node journal, which the operator cannot read,
// so the platform could not show either. This is ONE generic report for all of
// them, not a field per case: kind, subject, detail, first_seen.
const (
	// ConditionKnownDegradedUnit: a run-once unit that was already failing
	// before an in-place upgrade, which the upgrade therefore committed past
	// (V1's pre-existing-failure exemption), and which is still failing.
	// Subject is the systemd unit.
	ConditionKnownDegradedUnit = "known_degraded_unit"
	// ConditionSudoersRefused: a sudoers grant the render declined (illegal or
	// colliding drop-in name). Subject is "<module>/<grant id>".
	ConditionSudoersRefused = "sudoers_refused"
)

// AgentCondition is one standing condition. FirstSeen is RFC3339 UTC on the
// agent's own clock and is held stable for as long as the condition is
// continuously present; a condition that clears and returns starts a new run,
// and so does an agent restart (the run start is held in memory only, not in
// state.json).
type AgentCondition struct {
	Kind      string `json:"kind"`
	Subject   string `json:"subject"`
	Detail    string `json:"detail"`
	FirstSeen string `json:"first_seen"`
}

func agentConditionKey(kind, subject string) string { return kind + "\x00" + subject }

// recordAgentCondition notes, for THIS pass, that a condition holds. Called
// from RunOnce's own goroutine with r.mu held, so condPending needs no lock;
// nothing is visible to the heartbeat until publishAgentConditions.
func (r *Reconciler) recordAgentCondition(kind, subject, detail string) {
	r.condPending = append(r.condPending, AgentCondition{Kind: kind, Subject: subject, Detail: detail})
}

// resetAgentConditionPending starts a pass with nothing pending. It does NOT
// touch the published value: a pass that fails before it reaches the publish
// point must leave the previous verdict standing rather than read as "cleared".
func (r *Reconciler) resetAgentConditionPending() {
	r.condPending = nil
}

// noteSudoersVerdict records what the latest sudoers render decided. Only a
// render that actually ran to a verdict updates it: a clean apply (nil) or one
// whose only errors are refusals. A write failure says nothing about which
// grants would have been refused, so it leaves the previous verdict standing;
// and a pass that skips the render never calls this at all.
//
// KNOWN, ACCEPTED GAP: right after an agent restart there is no previous
// verdict, so a pass that skips the render (an unresolved real manifest) publishes
// no sudoers conditions, which reads as an all-clear for refusals nobody has
// looked at yet. It lasts only until the first render that runs, and only while
// a manifest is unresolved; the unresolved-manifest condition is itself reported
// (assignment_deferral identity_render_skipped).
func (r *Reconciler) noteSudoersVerdict(err error) {
	if err != nil && !etcsudoers.RefusalsOnly(err) {
		return
	}
	var conds []AgentCondition
	for _, ref := range collectRefusals(err) {
		conds = append(conds, AgentCondition{
			Kind:    ConditionSudoersRefused,
			Subject: fmt.Sprintf("%s/%s", ref.ModuleName, ref.GrantID),
			Detail:  ref.Reason,
		})
	}
	r.sudoersConds = conds
}

func collectRefusals(err error) []*etcsudoers.RefusedGrantError {
	var out []*etcsudoers.RefusedGrantError
	var ref *etcsudoers.RefusedGrantError
	switch {
	case err == nil:
	case errors.As(err, &ref) && !hasJoined(err):
		out = append(out, ref)
	default:
		if j, ok := err.(interface{ Unwrap() []error }); ok {
			for _, c := range j.Unwrap() {
				out = append(out, collectRefusals(c)...)
			}
		}
	}
	return out
}

func hasJoined(err error) bool {
	_, ok := err.(interface{ Unwrap() []error })
	return ok
}

// publishAgentConditions swaps the published set to this pass's, in ONE atomic
// store (mu is held for the whole pass, so the heartbeat goroutine reads the
// atomic and must only ever see a complete verdict). The set is the pass's
// pending conditions plus the latest sudoers verdict, deduplicated by
// kind+subject. An empty result is still PUBLISHED: that is the explicit,
// measured "no conditions", which the heartbeat sends as [] and which the
// platform must be able to tell from an agent that does not report at all.
func (r *Reconciler) publishAgentConditions() {
	now := r.nowUnixOrTime()
	stamp := time.Unix(now, 0).UTC().Format(time.RFC3339)

	merged := make(map[string]AgentCondition, len(r.condPending)+len(r.sudoersConds))
	for _, c := range append(append([]AgentCondition(nil), r.condPending...), r.sudoersConds...) {
		key := agentConditionKey(c.Kind, c.Subject)
		if _, dup := merged[key]; !dup {
			merged[key] = c
		}
	}

	if r.condFirstSeen == nil {
		r.condFirstSeen = map[string]string{}
	}
	for key := range r.condFirstSeen {
		if _, live := merged[key]; !live {
			delete(r.condFirstSeen, key) // cleared: a return starts a new run
		}
	}

	out := make([]AgentCondition, 0, len(merged))
	for key, c := range merged {
		since, ok := r.condFirstSeen[key]
		if !ok {
			since = stamp
			r.condFirstSeen[key] = since
		}
		c.FirstSeen = since
		out = append(out, c)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Kind != out[j].Kind {
			return out[i].Kind < out[j].Kind
		}
		return out[i].Subject < out[j].Subject
	})
	r.condPending = nil
	r.agentConditions.Store(&out)
}

// AgentConditions returns the standing conditions the last completed pass
// published, and whether any pass has published at all. measured=false means
// UNMEASURED (no pass has reached the publish point yet); measured=true with an
// empty slice means a pass looked and found nothing. Safe from any goroutine.
func (r *Reconciler) AgentConditions() ([]AgentCondition, bool) {
	p := r.agentConditions.Load()
	if p == nil {
		return nil, false
	}
	return append([]AgentCondition{}, (*p)...), true
}
