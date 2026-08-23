package probe

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// evaluatorFixture builds a self-contained attach-state + manifest cache in a
// temp dir. Every path is injected — nothing here reads the host's live
// /persist, which a const-path evaluator would have done on any machine that
// happens to be a fleet node.
type evaluatorFixture struct {
	statePath string
	root      string
}

func newEvaluatorFixture(t *testing.T, modules map[string]string) evaluatorFixture {
	t.Helper()
	base := t.TempDir()
	root := filepath.Join(base, "modules")

	attached := make([]map[string]any, 0, len(modules))
	for id, digest := range modules {
		attached = append(attached, map[string]any{"id": id, "digest": digest})
	}
	state := map[string]any{"attached_modules": attached}
	statePath := filepath.Join(base, "state.json")
	writeJSON(t, statePath, state)
	return evaluatorFixture{statePath: statePath, root: root}
}

func (f evaluatorFixture) writeManifest(t *testing.T, id, name string, config map[string]any) {
	t.Helper()
	dir := filepath.Join(f.root, id)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeJSON(t, filepath.Join(dir, "manifest.json"), map[string]any{
		"id": id, "name": name, "config": config, "services": []any{},
	})
}

func writeJSON(t *testing.T, path string, v any) {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, b, 0o644); err != nil {
		t.Fatal(err)
	}
}

func verifyConfig(name, command, resolvesTo string) map[string]any {
	return map[string]any{"verify": map[string]any{"probes": []any{
		map[string]any{"name": name, "command": command, "resolves_to": resolvesTo},
	}}}
}

func newFixtureEvaluator(f evaluatorFixture, r Runner) *Evaluator {
	e := NewEvaluator(nil)
	e.Runner = r
	e.StatePath = f.statePath
	e.Root = f.root
	return e
}

func TestEvaluator_ReportsOnlyProbeDeclaringModules(t *testing.T) {
	f := newEvaluatorFixture(t, map[string]string{"mod-a": "sha256:1", "mod-b": "sha256:2"})
	f.writeManifest(t, "mod-a", "gh", verifyConfig("gh-binary", "gh", "/usr/local/bin/gh"))
	f.writeManifest(t, "mod-b", "redis", map[string]any{"skills": []any{}})

	e := newFixtureEvaluator(f, scriptedRunner{byShell: map[string]string{
		"-lc": "/usr/local/bin/gh", "-c": "/usr/local/bin/gh",
	}})
	e.Refresh(context.Background())

	snap := e.Snapshot()
	if len(snap) != 1 || snap[0].ModuleID != "mod-a" {
		t.Fatalf("want one report for mod-a, got %+v", snap)
	}
	if len(snap[0].Probes) != 1 || len(snap[0].Probes[0].Shells) != 2 {
		t.Fatalf("want one probe with two shell results, got %+v", snap[0].Probes)
	}
}

// A node with nothing to verify must produce a nil snapshot, so the heartbeat
// OMITS the key. Sending an empty block would let the platform read "nothing
// to verify" as "verified, nothing wrong" — different facts.
func TestEvaluator_SnapshotIsNilWhenNothingDeclaresProbes(t *testing.T) {
	f := newEvaluatorFixture(t, map[string]string{"mod-b": "sha256:2"})
	f.writeManifest(t, "mod-b", "redis", map[string]any{})

	e := newFixtureEvaluator(f, scriptedRunner{})
	e.Refresh(context.Background())

	if snap := e.Snapshot(); snap != nil {
		t.Errorf("want nil snapshot (absence), got %+v", snap)
	}
}

// A changed digest re-probes IMMEDIATELY, interval be damned. A fresh deploy
// is the exact moment a bad publish is detectable; making the operator wait
// out a refresh interval to learn the deploy broke the node inverts the point.
func TestEvaluator_ReprobesImmediatelyOnDigestChange(t *testing.T) {
	f := newEvaluatorFixture(t, map[string]string{"mod-a": "sha256:1"})
	f.writeManifest(t, "mod-a", "gh", verifyConfig("gh-binary", "gh", "/usr/local/bin/gh"))

	good := scriptedRunner{byShell: map[string]string{"-lc": "/usr/local/bin/gh", "-c": "/usr/local/bin/gh"}}
	e := newFixtureEvaluator(f, good)
	e.Interval = time.Hour // long enough that only a digest change can re-run
	e.Refresh(context.Background())
	if e.Snapshot()[0].Probes[0].Shells[0].Status != StatusPass {
		t.Fatal("precondition: first pass should be green")
	}

	// Same digest + a now-broken node => the interval holds, snapshot unchanged.
	e.Runner = scriptedRunner{byShell: map[string]string{"-lc": "/usr/bin/gh", "-c": "/usr/bin/gh"}}
	e.Refresh(context.Background())
	if got := e.Snapshot()[0].Probes[0].Shells[0].Status; got != StatusPass {
		t.Errorf("interval should have suppressed the re-run, got %s", got)
	}

	// New digest => re-probe now, and the failure surfaces.
	writeJSON(t, f.statePath, map[string]any{"attached_modules": []any{
		map[string]any{"id": "mod-a", "digest": "sha256:2"},
	}})
	e.Refresh(context.Background())
	if got := e.Snapshot()[0].Probes[0].Shells[0].Status; got != StatusFail {
		t.Errorf("a new digest must re-probe immediately; got %s", got)
	}
}

// A detached module must stop reporting. Otherwise its last PASS stands
// forever for a capability the node no longer carries.
func TestEvaluator_PrunesDetachedModules(t *testing.T) {
	f := newEvaluatorFixture(t, map[string]string{"mod-a": "sha256:1"})
	f.writeManifest(t, "mod-a", "gh", verifyConfig("gh-binary", "gh", "/usr/local/bin/gh"))

	e := newFixtureEvaluator(f, scriptedRunner{byShell: map[string]string{
		"-lc": "/usr/local/bin/gh", "-c": "/usr/local/bin/gh",
	}})
	e.Refresh(context.Background())
	if len(e.Snapshot()) != 1 {
		t.Fatal("precondition: one report expected")
	}

	writeJSON(t, f.statePath, map[string]any{"attached_modules": []any{}})
	e.Refresh(context.Background())
	if snap := e.Snapshot(); snap != nil {
		t.Errorf("detached module still reporting: %+v", snap)
	}
}

// A module that DROPS its verify: block must stop reporting too — the old
// verdict describes a declaration that no longer exists.
func TestEvaluator_ForgetsModuleThatDropsItsVerifyBlock(t *testing.T) {
	f := newEvaluatorFixture(t, map[string]string{"mod-a": "sha256:1"})
	f.writeManifest(t, "mod-a", "gh", verifyConfig("gh-binary", "gh", "/usr/local/bin/gh"))

	e := newFixtureEvaluator(f, scriptedRunner{byShell: map[string]string{
		"-lc": "/usr/local/bin/gh", "-c": "/usr/local/bin/gh",
	}})
	e.Refresh(context.Background())
	if len(e.Snapshot()) != 1 {
		t.Fatal("precondition: one report expected")
	}

	f.writeManifest(t, "mod-a", "gh", map[string]any{})
	writeJSON(t, f.statePath, map[string]any{"attached_modules": []any{
		map[string]any{"id": "mod-a", "digest": "sha256:2"},
	}})
	e.Refresh(context.Background())
	if snap := e.Snapshot(); snap != nil {
		t.Errorf("module dropped its verify: block but still reports: %+v", snap)
	}
}
