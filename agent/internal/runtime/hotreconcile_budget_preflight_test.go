package runtime

import (
	"context"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// THE RATCHET. A scratch-budget abort does not just fail — it makes the next
// attempt fail harder, forever.
//
// SyncModuleFiles refuses a copy per FILE: it aborts on the first entry whose
// size would push the scratch below the floor, and everything it already wrote
// stays (hotreconcile.go:120-129 — the sync only ever adds or overwrites, and
// hotReconcileIfNeeded returns before the prune, so the module keeps serving its
// OLD content intact). Those already-written bytes are exactly the free space
// the retry needs. Resuming is otherwise free and correct — syncRegularFile runs
// filesIdentical BEFORE consulting the guard, so a file copied last tick costs
// zero budget this tick — but with less free space than before, the guard now
// refuses the first non-identical file it reaches REGARDLESS of size, and every
// later tick makes exactly zero progress.
//
// Live, ops-hub 2026-09-04: a 195-byte BUILD_INFO.json refused at 34 MB free
// against a 64 MiB floor, on a scratch whose 449 MB upper was largely the
// partial copies of earlier aborted ticks. It only cleared when an operator
// deleted 54 MB of cache by hand.
//
// Nothing escalated. The three-rung ladder (hot materialize -> soft-recompose
// --execute -> full reboot) exists and the second rung genuinely solves this:
// it composes at /run/nextroot against its OWN scratch tmpfs (mount.NextrootLayout,
// asserted by softreboot_test.go's next.ScratchRoot != live.ScratchRoot), so the
// diff costs zero bytes of the live upper. But the only thing pointing at it was
// prose in a log line; no code routed a module that cannot fit the hot rung to
// the rung that can take it.
//
// The fix is a PRE-FLIGHT rather than a post-hoc escalation, because the post-hoc
// form still consumes the space on the way to discovering it does not fit.

const (
	// Four files that each fit under the floor on their own, and do not as a
	// set. That split is the whole point: a per-file guard says yes twice and
	// then no, which is how the partial copy gets created.
	preflightFileSize = 200_000
	preflightFloor    = 500_000
	preflightFree     = 1_000_000
)

var preflightPayloadFiles = []string{"a.bin", "b.bin", "c.bin", "d.bin"}

// oversizeModulePayload writes 4 x 200_000 bytes under dir. Total 800_000
// against a 500_000-byte usable budget: the module can never fit the hot rung.
func oversizeModulePayload(t *testing.T, dir string) {
	t.Helper()
	body := strings.Repeat("x", preflightFileSize)
	for _, name := range preflightPayloadFiles {
		writeTestFile(t, filepath.Join(dir, "opt", "powernode", name), body, 0o644)
	}
}

// bytesMaterialized totals the regular-file bytes under root — the live root in
// these tests. It is the direct oracle for "did this tick copy anything",
// which the SyncResult.Changed count is not: the reconciler discards it, and
// after the fix there is no sync call to report one.
func bytesMaterialized(t *testing.T, root string) uint64 {
	t.Helper()
	var total uint64
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || d.Type()&fs.ModeSymlink != 0 {
			return nil
		}
		fi, ierr := d.Info()
		if ierr != nil {
			return ierr
		}
		total += uint64(fi.Size())
		return nil
	})
	if err != nil {
		t.Fatalf("walking the live root: %v", err)
	}
	return total
}

func hasSignal(signals []string, want string) bool {
	for _, s := range signals {
		if s == want {
			return true
		}
	}
	return false
}

// shrinkingScratch models the scratch honestly: every byte written to the live
// root is a byte the next free-space probe no longer sees. A constant stub
// cannot reproduce this defect at all — the ratchet IS the feedback from the
// partial copy back into the next probe.
func shrinkingScratch(t *testing.T, root string, initialFree uint64) {
	t.Helper()
	orig := freeBytesAt
	freeBytesAt = func(string) (uint64, error) {
		used := bytesMaterialized(t, root)
		if used >= initialFree {
			return 0, nil
		}
		return initialFree - used, nil
	}
	t.Cleanup(func() { freeBytesAt = orig })
}

// preflightPassesThenScratchVanishes stubs the free-space probe so the PRE-FLIGHT
// sees room and the per-file guard does not — the scratch filled up between the
// two, which on a live node is an ordinary concurrent copy-up.
//
// It is what keeps the mid-walk guard under test now that the pre-flight
// normally refuses first. The guard is not superseded by the pre-flight: the
// plan is an estimate taken at one instant, on a filesystem the reconciler does
// not own, and the pre-flight fails OPEN on a probe error.
//
// Coupled to the pre-flight probing exactly once — which fails closed, since a
// second generous answer would let the copy through and the callers' assertions
// on reconciler:recompose_budget would go red rather than quiet.
func preflightPassesThenScratchVanishes(t *testing.T, atPreflight, afterwards uint64) {
	t.Helper()
	orig := freeBytesAt
	calls := 0
	freeBytesAt = func(string) (uint64, error) {
		calls++
		if calls == 1 {
			return atPreflight, nil
		}
		return afterwards, nil
	}
	t.Cleanup(func() { freeBytesAt = orig })
}

func TestHotReconcile_OversizeModuleEscalatesInsteadOfRatcheting(t *testing.T) {
	forcePivotNative(t)
	r, layout, signals := budgetFixture(t)
	mod := mount.Module{ID: "hub-backend", Digest: "sha256:oversize"}
	oversizeModulePayload(t, layout.ModuleMountPath(mod.Digest))
	r.cfg.ScratchMinFreeBytes = preflightFloor
	shrinkingScratch(t, layout.Root, preflightFree)

	mf := &manifest.Manifest{}

	// TICK 1. The module cannot fit the hot rung under any ordering, so the
	// reconciler must not write a single byte of it: the partial copy is what
	// consumes the space the retry needs.
	retry := r.hotReconcileIfNeeded(mod, mf, false, nil, mount.ModuleStack{mod})
	if got := bytesMaterialized(t, layout.Root); got != 0 {
		t.Fatalf("tick 1 materialized %d bytes of a module that cannot fit the budget; "+
			"those bytes are exactly the free space the next tick needs, which is the ratchet", got)
	}
	if !hasSignal(*signals, "reconciler:recompose_escalate") {
		t.Fatalf("tick 1 emitted no escalation signal; signals=%v — nothing routes this module "+
			"to the rung that can take it", *signals)
	}
	if !retry {
		t.Fatalf("tick 1 returned retryNeeded=false; the caller then keeps the manifest-hash stamp " +
			"AND stops recording the module as unmaterialized, so the heartbeat resumes claiming " +
			"the unwritten version is running (regressing f72ede5a)")
	}

	// TICK 2. The acceptance condition: no second refused copy. The in-walk
	// guard signal (reconciler:recompose_budget) firing again would mean the
	// reconciler re-entered a sync it already knows cannot fit.
	mark := len(*signals)
	retry2 := r.hotReconcileIfNeeded(mod, mf, false, nil, mount.ModuleStack{mod})
	tick2 := (*signals)[mark:]

	if got := bytesMaterialized(t, layout.Root); got != 0 {
		t.Fatalf("tick 2 materialized %d bytes; the module still cannot fit", got)
	}
	if hasSignal(tick2, "reconciler:recompose_budget") {
		t.Fatalf("tick 2 re-attempted the hot sync and was refused mid-walk again (signals=%v); "+
			"a module already known not to fit must be routed, not retried", tick2)
	}
	if !hasSignal(tick2, "reconciler:recompose_escalate") {
		t.Fatalf("tick 2 went quiet (signals=%v); a stuck module that reads as resolved is the "+
			"failure mode the retry lever was added to fix", tick2)
	}
	if !retry2 {
		t.Fatalf("tick 2 returned retryNeeded=false; the module would drop out of toReattach and " +
			"stop being reported as unmaterialized while it is still stuck")
	}
}

// CONTROL: the pre-flight must not become a blanket refusal. A module whose
// content fits is still materialized in full, with no escalation.
func TestHotReconcile_FittingModuleStillMaterializes(t *testing.T) {
	forcePivotNative(t)
	r, layout, signals := budgetFixture(t)
	mod := mount.Module{ID: "hub-frontend", Digest: "sha256:fits"}
	oversizeModulePayload(t, layout.ModuleMountPath(mod.Digest))
	r.cfg.ScratchMinFreeBytes = preflightFloor
	// 2 MB free against a 500 KB floor leaves 1.5 MB usable for an 800 KB diff.
	shrinkingScratch(t, layout.Root, 2_000_000)

	if r.hotReconcileIfNeeded(mod, &manifest.Manifest{}, false, nil, mount.ModuleStack{mod}) {
		t.Fatalf("a module that fits requested a retry; signals=%v", *signals)
	}
	want := uint64(len(preflightPayloadFiles) * preflightFileSize)
	if got := bytesMaterialized(t, layout.Root); got != want {
		t.Fatalf("materialized %d bytes, want %d — the pre-flight refused a module that fits", got, want)
	}
	if hasSignal(*signals, "reconciler:recompose_escalate") || hasSignal(*signals, "reconciler:recompose_budget") {
		t.Fatalf("a fitting module produced a budget signal: %v", *signals)
	}
}

// BOUNDARY: a diff that exactly exhausts the usable budget FITS. The floor is
// what the budget already reserves, so refusing at equality would reserve it
// twice and push a module onto the soft-reboot rung that the hot rung can take.
func TestHotReconcile_PreflightAdmitsAnExactFit(t *testing.T) {
	forcePivotNative(t)
	r, layout, signals := budgetFixture(t)
	mod := mount.Module{ID: "hub-worker", Digest: "sha256:exact"}
	oversizeModulePayload(t, layout.ModuleMountPath(mod.Digest))

	required := uint64(len(preflightPayloadFiles) * preflightFileSize)
	r.cfg.ScratchMinFreeBytes = preflightFloor
	// free - floor == required, to the byte.
	orig := freeBytesAt
	freeBytesAt = func(string) (uint64, error) { return required + preflightFloor, nil }
	t.Cleanup(func() { freeBytesAt = orig })

	if r.hotReconcileIfNeeded(mod, &manifest.Manifest{}, false, nil, mount.ModuleStack{mod}) {
		t.Fatalf("an exactly-fitting diff was refused; signals=%v", *signals)
	}
	if got := bytesMaterialized(t, layout.Root); got != required {
		t.Fatalf("materialized %d bytes, want %d", got, required)
	}
}

// The plan must price a contested path from the layer that would actually be
// WRITTEN. SyncModuleFiles resolves a path a higher-priority layer also ships to
// that layer's content (findInLayers + restoreFrom, the union winner), so a plan
// that priced this module's own copy would admit a materialization that then
// blows the budget on the winner's much larger file — the pre-flight would be
// measuring a tree nobody copies.
func TestHotReconcile_PreflightPricesTheContestedWinner(t *testing.T) {
	forcePivotNative(t)
	r, layout, signals := budgetFixture(t)

	loser := mount.Module{ID: "hub-backend", Digest: "sha256:loser", Priority: 100}
	winner := mount.Module{ID: "base-os", Digest: "sha256:winner", Priority: 900}
	const shared = "opt/powernode/contested.bin"

	// The loser ships 10 bytes at the shared path; the winner ships 400_000.
	writeTestFile(t, filepath.Join(layout.ModuleMountPath(loser.Digest), shared), "0123456789", 0o644)
	writeTestFile(t, filepath.Join(layout.ModuleMountPath(winner.Digest), shared),
		strings.Repeat("w", 400_000), 0o644)

	r.cfg.ScratchMinFreeBytes = preflightFloor
	// 200_000 usable: the loser's 10 bytes fit trivially, the winner's do not.
	orig := freeBytesAt
	freeBytesAt = func(string) (uint64, error) { return 200_000 + preflightFloor, nil }
	t.Cleanup(func() { freeBytesAt = orig })

	if !r.hotReconcileIfNeeded(loser, &manifest.Manifest{}, false, nil, mount.ModuleStack{loser, winner}) {
		t.Fatalf("the contested materialization was admitted; signals=%v", *signals)
	}
	if !hasSignal(*signals, "reconciler:recompose_escalate") {
		t.Fatalf("expected an escalation priced on the winner's content, got %v", *signals)
	}
	if got := bytesMaterialized(t, layout.Root); got != 0 {
		t.Fatalf("materialized %d bytes; the pre-flight priced the wrong layer and let the copy start", got)
	}
}

// CONTROL: already-materialized files must cost the PRE-FLIGHT nothing, exactly
// as they cost the copy nothing (syncRegularFile runs filesIdentical before the
// guard). Without this the pre-flight would price a module by its whole tree and
// refuse a resume that plainly fits — converting the ratchet into a permanent
// refusal, which is worse.
func TestHotReconcile_PreflightPricesOnlyTheRemainingDiff(t *testing.T) {
	forcePivotNative(t)
	r, layout, signals := budgetFixture(t)
	mod := mount.Module{ID: "hub-backend", Digest: "sha256:resume"}
	src := layout.ModuleMountPath(mod.Digest)
	oversizeModulePayload(t, src)

	// Three of the four files are already on the live root, byte-identical —
	// the state a partial copy (or a completed earlier tick) leaves behind.
	body := strings.Repeat("x", preflightFileSize)
	for _, name := range preflightPayloadFiles[:3] {
		writeTestFile(t, filepath.Join(layout.Root, "opt", "powernode", name), body, 0o644)
	}

	r.cfg.ScratchMinFreeBytes = preflightFloor
	// Fixed probe: 900_000 free, 500_000 floor => 400_000 usable. The whole
	// tree (800_000) does not fit; the remaining file (200_000) does.
	orig := freeBytesAt
	freeBytesAt = func(string) (uint64, error) { return 900_000, nil }
	t.Cleanup(func() { freeBytesAt = orig })

	if r.hotReconcileIfNeeded(mod, &manifest.Manifest{}, false, nil, mount.ModuleStack{mod}) {
		t.Fatalf("a resume whose remaining diff fits requested a retry; signals=%v", *signals)
	}
	if hasSignal(*signals, "reconciler:recompose_escalate") {
		t.Fatalf("the pre-flight priced already-identical files and escalated a resume that fits: %v", *signals)
	}
	last := filepath.Join(layout.Root, "opt", "powernode", preflightPayloadFiles[3])
	if _, err := os.Stat(last); err != nil {
		t.Fatalf("the remaining file was not materialized: %v", err)
	}
}

// The sibling fix (IMP-bc1b0495352d, f72ede5a) must survive the escalation: a
// node that escalates has NOT written the new version's files, so the heartbeat
// must still omit its digest and the state must still list it as unmaterialized.
// Asserted through RunOnce + buildHeartbeat, the production path, not the
// single-module helper.
func TestHeartbeatOmitsDigestOfEscalatedModule(t *testing.T) {
	r, statePath := budgetReportingFixture(t)
	r.cfg.ScratchMinFreeBytes = ^uint64(0) >> 1 // no filesystem satisfies this floor

	var signals []string
	r.cfg.OnError = func(kind string, _ error) { signals = append(signals, kind) }

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	if !hasSignal(signals, "reconciler:recompose_escalate") {
		t.Fatalf("fixture did not reach the escalation; signals=%v", signals)
	}
	st, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	if len(st.UnmaterializedModules) != 1 || st.UnmaterializedModules[0] != "m1" {
		t.Fatalf("UnmaterializedModules = %v, want [m1] — an escalated module is mounted but not running",
			st.UnmaterializedModules)
	}
	if got, ok := heartbeatFrom(t, statePath).ModuleDigests["m1"]; ok {
		t.Fatalf("heartbeat reports m1 running digest %q after the materialization was ESCALATED, "+
			"not performed; that is the false 'deployed' signal f72ede5a removed", got)
	}
}
