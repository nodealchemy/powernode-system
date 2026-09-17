package signingaudit

import (
	"errors"
	"strings"
	"testing"
)

// The audit rungs report the SAME finding every tick: a failing attach repeats
// on every reconcile, and the fs-verity arm reports twice per tick per module
// (prefetch and attach). A collector that kept one entry per report would ship
// an unbounded, mostly duplicated list on every heartbeat.
func TestCollectorCountsRepeatsInsteadOfGrowing(t *testing.T) {
	c := New(8)
	for i := 0; i < 5; i++ {
		c.Report("verify:module_signature_audit", errors.New("would refuse /b/one: no cosign bundle"))
	}

	snap := c.Snapshot()
	if snap == nil || len(snap.Findings) != 1 {
		t.Fatalf("one distinct finding must stay one entry, got %+v", snap)
	}
	f := snap.Findings[0]
	if f.Count != 5 {
		t.Errorf("count must carry the repeats, got %d", f.Count)
	}
	if f.Stage != "verify:module_signature_audit" {
		t.Errorf("stage lost: %q", f.Stage)
	}
	if !strings.Contains(f.Detail, "/b/one") {
		t.Errorf("detail must name the blob the enforcing mode would refuse: %q", f.Detail)
	}
	if f.FirstSeen == "" || f.LastSeen == "" {
		t.Errorf("both timestamps must be set: %+v", f)
	}
}

// Distinct findings are distinct rows: the operator needs to know WHICH blobs
// would be refused, not just how many reports happened.
func TestCollectorKeepsDistinctFindingsApart(t *testing.T) {
	c := New(8)
	c.Report("verify:module_signature_audit", errors.New("would refuse /b/one: no cosign bundle"))
	c.Report("verify:module_fsverity_audit", errors.New("would refuse /b/two: no fsverity_root_hash published"))

	if got := len(c.Snapshot().Findings); got != 2 {
		t.Fatalf("two distinct findings, got %d", got)
	}
}

// THE MEASUREMENT THE LADDER WAITS FOR. Enforcing is justified by the ABSENCE
// of findings, so "audit ran here and this node is quiet" has to reach the
// platform as a positive fact. A collector that reports only findings delivers
// presence and drops absence, which leaves the operator exactly where the task
// found them: unable to tell quiet from never-measured.
func TestActiveAndQuietCollectorSnapshotsAsAMeasurement(t *testing.T) {
	c := New(8)
	c.MarkActive("audit")

	snap := c.Snapshot()
	if snap == nil {
		t.Fatal("an ACTIVE collector with nothing to report must snapshot as a measurement, not as nil")
	}
	if len(snap.Findings) != 0 {
		t.Errorf("a quiet node reports no findings, got %+v", snap.Findings)
	}
	if snap.Truncated {
		t.Error("nothing was dropped")
	}
	// Without the rung, an empty list cannot be attributed: under runtime/all
	// the signature arm enforces and reports nothing, so "quiet" there covers
	// only the fs-verity arm.
	if snap.Mode != "audit" {
		t.Errorf("the rung that produced this measurement must ride with it, got %q", snap.Mode)
	}
}

// The rung is normalized and carried verbatim otherwise, so a reader never has
// to guess whether `Runtime` and `runtime` are the same measurement.
func TestCollectorCarriesTheRungThatProducedTheMeasurement(t *testing.T) {
	c := New(8)
	c.MarkActive("  RUNTIME ")

	if got := c.Snapshot().Mode; got != "runtime" {
		t.Errorf("mode must be normalized, got %q", got)
	}
}

// The other side of the same distinction: a node that never ran audit (signing
// `off`) must stay NOT MEASURED, so the platform records an absence rather than
// a clean-looking empty block.
func TestInactiveCollectorSnapshotsAsNil(t *testing.T) {
	if snap := New(8).Snapshot(); snap != nil {
		t.Fatalf("an inactive, silent collector must snapshot as nil, got %+v", snap)
	}
	var nilCollector *Collector
	if snap := nilCollector.Snapshot(); snap != nil {
		t.Fatalf("a nil collector must snapshot as nil, got %+v", snap)
	}
	nilCollector.Report("verify:module_signature_audit", errors.New("boom")) // must not panic
	nilCollector.MarkActive("audit")                                         // must not panic
}

// A finding still reaches the platform even if nothing marked the collector
// active: dropping a real finding because a wiring step was missed would hide
// the very thing this block exists to carry.
func TestFindingsReachTheWireEvenWhenActiveWasNeverMarked(t *testing.T) {
	c := New(8)
	c.Report("verify:module_signature_audit", errors.New("would refuse /b/one: no cosign bundle"))

	if snap := c.Snapshot(); snap == nil || len(snap.Findings) != 1 {
		t.Fatalf("a reported finding must snapshot regardless of the active flag, got %+v", snap)
	}
}

// A node whose whole module set is unsigned must not turn the heartbeat into an
// unbounded upload. The cap drops NEW distinct findings; it never silently
// stops counting the ones already known, and the drop is VISIBLE — otherwise
// finding_count reads as "this node's problems" when it is only the size of the
// window, and an operator backfilling blobs never learns how many were unnamed.
func TestCollectorCapsDistinctFindingsAndReportsTheTruncation(t *testing.T) {
	c := New(2)
	c.Report("verify:module_signature_audit", errors.New("would refuse /b/one: x"))
	c.Report("verify:module_signature_audit", errors.New("would refuse /b/two: x"))
	c.Report("verify:module_signature_audit", errors.New("would refuse /b/three: x"))
	c.Report("verify:module_signature_audit", errors.New("would refuse /b/one: x"))

	snap := c.Snapshot()
	if len(snap.Findings) != 2 {
		t.Fatalf("cap must bound the distinct entries, got %d", len(snap.Findings))
	}
	if !snap.Truncated {
		t.Error("a dropped finding must ride the wire as truncation, never be silent")
	}
	var one Finding
	for _, f := range snap.Findings {
		if strings.Contains(f.Detail, "/b/one") {
			one = f
		}
	}
	if one.Count != 2 {
		t.Errorf("a known finding keeps counting after the cap is reached, got %d", one.Count)
	}
}

// The collector is a TEE, not a replacement: the stderr hook the service and
// CLI already install must keep receiving every report, or this change would
// trade a local signal for a remote one.
func TestTeePreservesTheUnderlyingHook(t *testing.T) {
	c := New(8)
	var sawStage string
	report := c.Tee(func(stage string, _ error) { sawStage = stage })

	report("verify:module_fsverity_audit", errors.New("would refuse /b/x: fsverity: executable file not found"))

	if sawStage != "verify:module_fsverity_audit" {
		t.Errorf("the wrapped hook must still see the report, got %q", sawStage)
	}
	if len(c.Snapshot().Findings) != 1 {
		t.Error("the tee must also collect")
	}
	// A nil inner hook is the CLI's shape before it installs one; teeing must
	// not require it.
	c2 := New(8)
	c2.Tee(nil)("verify:module_signature_audit", errors.New("would refuse /b/y: z"))
	if len(c2.Snapshot().Findings) != 1 {
		t.Error("tee over a nil hook must still collect")
	}
}

// THE MEASUREMENT'S OWN FAILURE MODES BELONG IN THE BLOCK. A non-enforcing site
// with no trust anchor degrades to verify.AlwaysOK and reports
// `verify:module_signing` — the node is configured for audit and is verifying
// NOTHING. Dropping that stage would let such a node report finding_count 0,
// i.e. a positive claim of QUIET from a node that measured nothing, delivered
// exactly when the operator is deciding to enforce.
func TestCollectorRecordsTheMeasurementsOwnFailureModes(t *testing.T) {
	c := New(8)
	c.MarkActive("audit")
	c.Report("verify:module_signing", errors.New("module signing audit at service degraded to no verification: no trusted public key"))
	c.Report("verify:module_signing_keys", errors.New("refresh platform module-signing keys: dial tcp: connection refused (using the cached set, if any)"))

	snap := c.Snapshot()
	if len(snap.Findings) != 2 {
		t.Fatalf("a degraded verifier and a failed key refresh are findings, not silence: %+v", snap)
	}
	if snap.Findings[0].Stage != "verify:module_signing" {
		t.Errorf("degrade stage lost: %+v", snap.Findings[0])
	}
}

// Only this measurement's stages belong in the block. Every other OnError stage
// the agent reports (compose:*, hostname_apply, a2a, …) is a different
// measurement with a different reader, and folding them in would make the
// platform's signing-audit document mean "any agent error".
func TestCollectorIgnoresStagesThatAreNotSigningStages(t *testing.T) {
	c := New(8)
	c.Report("compose:identity_write", errors.New("permission denied"))
	c.Report("hostname_apply", errors.New("nope"))

	if snap := c.Snapshot(); snap != nil {
		t.Fatalf("unrelated stages must not enter the signing-audit block, got %+v", snap)
	}
}

// The detail is an error string that can embed a path and a command's whole
// output, and it crosses to a platform read surface on every heartbeat. The
// server has its own bound, but relying on that would mean shipping the
// oversized text over the wire first.
func TestCollectorBoundsTheDetailItPutsOnTheWire(t *testing.T) {
	c := New(8)
	c.Report("verify:module_signature_audit", errors.New("would refuse /b/one: "+strings.Repeat("x", 5_000)))

	detail := c.Snapshot().Findings[0].Detail
	if len(detail) > MaxDetailChars+len("…") {
		t.Errorf("detail must be bounded to %d chars, got %d", MaxDetailChars, len(detail))
	}
	if !strings.HasPrefix(detail, "would refuse /b/one: ") {
		t.Errorf("truncation must keep the head, which names the blob: %q", detail)
	}
}

// The two arms can produce the SAME detail text for the same blob. If the
// dedup key were the detail alone they would collapse into one row with a
// doubled count, and the document would silently lose which arm is failing —
// the one thing a reader gates on.
func TestCollectorKeepsTheArmsApartWhenTheDetailMatches(t *testing.T) {
	c := New(8)
	same := "would refuse /persist/blobs/aa: unreadable"
	c.Report(StageSignature, errors.New(same))
	c.Report(StageFsverity, errors.New(same))

	snap := c.Snapshot()
	if len(snap.Findings) != 2 {
		t.Fatalf("an identical detail from two arms is two findings, got %+v", snap.Findings)
	}
	for _, f := range snap.Findings {
		if f.Count != 1 {
			t.Errorf("neither arm's count may absorb the other's report: %+v", f)
		}
	}
}
