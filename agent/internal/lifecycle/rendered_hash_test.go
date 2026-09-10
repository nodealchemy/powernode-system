package lifecycle

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// IMP-01a05efa — the re-attach gate must stamp what the agent WRITES, not what
// the manifest says.
//
// manifest.ServicesHash covers manifest content only. RenderUnitModeGraph also
// folds in the root mode and the inverted dependency graph, and is the
// renderer's own logic besides — so a corrected renderer shipped in a new agent
// binary left every stamp byte-identical and no module was ever re-rendered.

func svcSet() []manifest.Service {
	return []manifest.Service{
		{Name: "api", StartCommand: "/usr/bin/api", RestartPolicy: "always"},
		{Name: "worker", StartCommand: "/usr/bin/worker", Dependencies: []string{"api"}},
	}
}

func TestRenderedServicesHash_Deterministic(t *testing.T) {
	a := RenderedServicesHash("m1", svcSet(), RootModeNative)
	b := RenderedServicesHash("m1", svcSet(), RootModeNative)
	if a != b {
		t.Fatalf("not deterministic: %s vs %s", a, b)
	}
	if a == "" {
		t.Fatal("empty hash for a non-empty service set")
	}
}

// Order of the input slice must not move the hash — the reconciler has no
// guarantee about the order the platform serves services in.
func TestRenderedServicesHash_IndependentOfInputOrder(t *testing.T) {
	forward := svcSet()
	reversed := svcSet()
	sort.Slice(reversed, func(i, j int) bool { return reversed[i].Name > reversed[j].Name })

	if RenderedServicesHash("m1", forward, RootModeNative) != RenderedServicesHash("m1", reversed, RootModeNative) {
		t.Fatal("hash moved with input order")
	}
}

// THE DEFECT, DIRECTLY. Identical manifest content, different RENDERED output:
// manifest.ServicesHash cannot tell these apart and the rendered hash must.
func TestRenderedServicesHash_MovesWhenOnlyTheRenderingDiffers(t *testing.T) {
	services := svcSet()

	mf := &manifest.Manifest{Services: services}
	if mf.ServicesHash() != (&manifest.Manifest{Services: services}).ServicesHash() {
		t.Fatal("precondition: manifest hash should be stable for identical content")
	}

	native := RenderedServicesHash("m1", services, RootModeNative)
	chroot := RenderedServicesHash("m1", services, RootModeChroot)
	if native == chroot {
		t.Fatal("rendered hash is blind to the root mode — the manifest-hash defect, reproduced")
	}
}

func TestRenderedServicesHash_EmptyAndNil(t *testing.T) {
	if RenderedServicesHash("m1", nil, RootModeNative) != "" {
		t.Fatal("nil services should hash to the empty string")
	}
	if RenderedServicesHash("m1", []manifest.Service{}, RootModeNative) != "" {
		t.Fatal("empty services should hash to the empty string")
	}
}

// ANTI-DRIFT. The hash is only meaningful while it describes the bytes
// AttachServicesModeOpts actually writes. Render through the hash, attach for
// real, then hash the files on disk the same way and compare — if the two
// paths ever diverge, this fails rather than the gate silently going blind
// again.
func TestRenderedServicesHash_MatchesTheFilesAttachWrites(t *testing.T) {
	dir := setUnitDir(t)
	services := svcSet()

	runner := &mount.RecorderRunner{}
	if _, err := AttachServicesModeOpts(context.Background(), runner, "m1", services, RootModeNative, AttachOptions{}); err != nil {
		t.Fatalf("AttachServicesModeOpts: %v", err)
	}

	// Same construction RenderedServicesHash uses: unit name, NUL, body, NUL,
	// in service-name order.
	ordered := append([]manifest.Service(nil), services...)
	sort.Slice(ordered, func(i, j int) bool { return ordered[i].Name < ordered[j].Name })

	h := sha256.New()
	for _, svc := range ordered {
		unit := UnitName("m1", svc.Name)
		body, err := os.ReadFile(filepath.Join(dir, unit))
		if err != nil {
			t.Fatalf("read %s: %v", unit, err)
		}
		h.Write([]byte(unit))
		h.Write([]byte{0})
		h.Write(body)
		h.Write([]byte{0})
	}
	onDisk := hex.EncodeToString(h.Sum(nil))

	if got := RenderedServicesHash("m1", services, RootModeNative); got != onDisk {
		t.Fatalf("hash does not describe the written files:\n  hash    = %s\n  on disk = %s", got, onDisk)
	}
}

// --- restart-on-change --------------------------------------------------

func invocationsOf(r *mount.RecorderRunner, verb string) []string {
	var out []string
	for _, inv := range r.Invocations {
		if inv.Name != "systemctl" || len(inv.Args) < 2 || inv.Args[0] != verb {
			continue
		}
		out = append(out, inv.Args[1])
	}
	return out
}

// A CHANGED body on an ACTIVE unit must be restarted: `systemctl start` is a
// no-op on a running service, so without this the corrected unit reaches the
// disk and never the process.
func TestAttachServicesModeOpts_RestartsChangedActiveUnit(t *testing.T) {
	dir := setUnitDir(t)
	services := []manifest.Service{{Name: "api", StartCommand: "/usr/bin/api"}}

	// Pre-place a DIFFERENT body so this pass rewrites it.
	if err := os.WriteFile(filepath.Join(dir, UnitName("m1", "api")), []byte("[Unit]\n# stale\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	runner := &mount.RecorderRunner{
		StubOutput: map[string][]byte{
			"systemctl is-active " + UnitName("m1", "api"): []byte("active\n"),
		},
	}
	results, err := AttachServicesModeOpts(context.Background(), runner, "m1", services, RootModeNative,
		AttachOptions{RestartChanged: true})
	if err != nil {
		t.Fatalf("AttachServicesModeOpts: %v", err)
	}

	if got := invocationsOf(runner, "restart"); len(got) != 1 || got[0] != UnitName("m1", "api") {
		t.Fatalf("expected one restart of the changed unit, got restarts=%v starts=%v",
			got, invocationsOf(runner, "start"))
	}
	if !results[0].Restarted {
		t.Error("AttachResult.Restarted should record the restart")
	}
}

// An UNCHANGED body is never disturbed, even with RestartChanged on — that is
// what keeps the one-pass-per-agent-upgrade re-attach cheap.
func TestAttachServicesModeOpts_LeavesUnchangedUnitAlone(t *testing.T) {
	setUnitDir(t)
	services := []manifest.Service{{Name: "api", StartCommand: "/usr/bin/api"}}
	ctx := context.Background()

	first := &mount.RecorderRunner{}
	if _, err := AttachServicesModeOpts(ctx, first, "m1", services, RootModeNative, AttachOptions{}); err != nil {
		t.Fatalf("seed attach: %v", err)
	}

	runner := &mount.RecorderRunner{
		StubOutput: map[string][]byte{
			"systemctl is-active " + UnitName("m1", "api"): []byte("active\n"),
		},
	}
	if _, err := AttachServicesModeOpts(ctx, runner, "m1", services, RootModeNative,
		AttachOptions{RestartChanged: true}); err != nil {
		t.Fatalf("second attach: %v", err)
	}

	if got := invocationsOf(runner, "restart"); len(got) != 0 {
		t.Fatalf("an unchanged unit must not be restarted, got %v", got)
	}
}

// A CHANGED body on an INACTIVE unit gets the ordinary start, not a restart: a
// deliberately stopped service must not be brought up by the back door.
func TestAttachServicesModeOpts_DoesNotRestartInactiveUnit(t *testing.T) {
	dir := setUnitDir(t)
	services := []manifest.Service{{Name: "api", StartCommand: "/usr/bin/api"}}
	if err := os.WriteFile(filepath.Join(dir, UnitName("m1", "api")), []byte("[Unit]\n# stale\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	runner := &mount.RecorderRunner{
		StubOutput: map[string][]byte{
			"systemctl is-active " + UnitName("m1", "api"): []byte("inactive\n"),
		},
	}
	if _, err := AttachServicesModeOpts(context.Background(), runner, "m1", services, RootModeNative,
		AttachOptions{RestartChanged: true}); err != nil {
		t.Fatalf("AttachServicesModeOpts: %v", err)
	}

	if got := invocationsOf(runner, "restart"); len(got) != 0 {
		t.Fatalf("an inactive unit must not be restarted, got %v", got)
	}
	if got := invocationsOf(runner, "start"); len(got) != 1 {
		t.Fatalf("expected the ordinary start, got %v", got)
	}
}

// The zero AttachOptions is the pre-existing behaviour, which is what lets
// every other caller stay unchanged.
func TestAttachServicesModeOpts_DefaultNeverRestarts(t *testing.T) {
	dir := setUnitDir(t)
	services := []manifest.Service{{Name: "api", StartCommand: "/usr/bin/api"}}
	if err := os.WriteFile(filepath.Join(dir, UnitName("m1", "api")), []byte("[Unit]\n# stale\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	runner := &mount.RecorderRunner{
		StubOutput: map[string][]byte{
			"systemctl is-active " + UnitName("m1", "api"): []byte("active\n"),
		},
	}
	if _, err := AttachServicesMode(context.Background(), runner, "m1", services, RootModeNative); err != nil {
		t.Fatalf("AttachServicesMode: %v", err)
	}

	if got := invocationsOf(runner, "restart"); len(got) != 0 {
		t.Fatalf("the default path must not restart, got %v", got)
	}
	if !strings.HasPrefix(UnitName("m1", "api"), "powernode-") {
		t.Fatal("unit naming precondition changed")
	}
}
