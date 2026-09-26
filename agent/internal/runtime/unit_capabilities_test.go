package runtime

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/security"
	"github.com/nodealchemy/powernode-system/agent/internal/verify"
)

// IMP-caef5c00d63f — per-service capabilities. The module's
// security.capabilities is a ceiling; each service resolves to its own
// declared subset, or inherits the ceiling when it declares nothing. Both
// attach paths — the cloud-init reconcile (attachModule) and the pivot compose
// (ComposeForPivot) — resolve through ONE function, and these tests pin that
// they agree.

// hubBackendLike decodes from JSON on purpose: presence is a property of the
// wire form, and a Go literal cannot express "the key was absent".
func hubBackendLike(t *testing.T) *manifest.Manifest {
	t.Helper()
	var mf manifest.Manifest
	body := `{
	  "id": "hub-backend",
	  "service_capabilities_presence": true,
	  "config": {"security": {"capabilities": ["CAP_CHOWN", "CAP_FOWNER", "CAP_DAC_OVERRIDE"]}},
	  "services": [
	    {"name": "rails-setup", "start_command": "/usr/local/bin/rails-setup.sh"},
	    {"name": "rails", "start_command": "/usr/local/bin/rails-start.sh", "user": "powernode-rails", "capabilities": []},
	    {"name": "chowner", "start_command": "/bin/true", "capabilities": ["CAP_CHOWN"]}
	  ]
	}`
	if err := json.Unmarshal([]byte(body), &mf); err != nil {
		t.Fatalf("decode fixture: %v", err)
	}
	return &mf
}

func capsByUnit(t *testing.T, writes []security.UnitCapabilities) map[string][]string {
	t.Helper()
	out := make(map[string][]string, len(writes))
	for _, w := range writes {
		allow := append([]string{}, w.Allow...)
		sort.Strings(allow)
		out[w.Unit] = allow
	}
	return out
}

func TestUnitCapabilities_ResolvesPerService(t *testing.T) {
	mf := hubBackendLike(t)
	writes, err := attachCapabilityWrites(mf, buildPolicy(mf))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	got := capsByUnit(t, writes)
	want := map[string][]string{
		"powernode-hub-backend-rails-setup.service": {"CAP_CHOWN", "CAP_DAC_OVERRIDE", "CAP_FOWNER"},
		"powernode-hub-backend-rails.service":       {},
		"powernode-hub-backend-chowner.service":     {"CAP_CHOWN"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("resolved per-unit sets:\n got  %v\n want %v", got, want)
	}
}

// PARITY. Both paths must hand every unit the same RESOLVED set.
//
// They still write it differently, deliberately and outside this task:
// attachModule's WriteCapabilityDropIn resets CapabilityBoundingSet and sets
// bounding + ambient to the resolved set, while the pivot path's
// WriteAmbientCapabilityDropInAt only ADDS the resolved set to the ambient set,
// never resets the bounding set, and writes nothing for an empty set (see the
// ComposeForPivot loop header and the heartbeat's PivotConfinementOmitted).
// So a unit that resolves to zero gets an empty bounding set on a cloud-init
// node and simply no ambient grant on a pivot node. The drop-in BYTES are
// therefore not comparable; the resolved per-unit set is, and that is what
// this pins.
func TestUnitCapabilities_ReconcileAndComposeResolveIdentically(t *testing.T) {
	mf := hubBackendLike(t)
	policy := buildPolicy(mf)

	attach, err := attachCapabilityWrites(mf, policy)
	if err != nil {
		t.Fatalf("attach: %v", err)
	}
	compose, err := composeCapabilityWrites(mf.ID, mf, policy)
	if err != nil {
		t.Fatalf("compose: %v", err)
	}
	if a, c := capsByUnit(t, attach), capsByUnit(t, compose); !reflect.DeepEqual(a, c) {
		t.Fatalf("reconcile and compose disagree on per-unit capabilities:\n reconcile %v\n compose   %v", a, c)
	}
}

func TestUnitCapabilities_BothPathsRefuseASetWiderThanTheCeiling(t *testing.T) {
	var mf manifest.Manifest
	body := `{
	  "id": "m",
	  "service_capabilities_presence": true,
	  "config": {"security": {"capabilities": ["CAP_CHOWN"]}},
	  "services": [{"name": "greedy", "start_command": "/bin/true", "capabilities": ["CAP_SYS_ADMIN"]}]
	}`
	if err := json.Unmarshal([]byte(body), &mf); err != nil {
		t.Fatal(err)
	}
	policy := buildPolicy(&mf)
	if _, err := attachCapabilityWrites(&mf, policy); err == nil {
		t.Error("reconcile path must refuse a service capability outside the module ceiling")
	}
	if _, err := composeCapabilityWrites(mf.ID, &mf, policy); err == nil {
		t.Error("compose path must refuse a service capability outside the module ceiling")
	}
}

// A change confined to one service's own capabilities key must move the
// re-attach stamp; otherwise an already-attached node never rewrites that
// unit's drop-in (the IMP-f5c0afa7183a defect class, one field over).
func TestAttachStamp_MovesWhenOnlyAServiceCapabilitySetChanges(t *testing.T) {
	inherit := hubBackendLike(t)
	zeroed := hubBackendLike(t)
	zeroed.Services[0].Capabilities = manifest.ServiceCapabilities{Declared: true, Names: []string{}}

	r := &Reconciler{}
	if r.attachStamp("hub-backend", inherit) == r.attachStamp("hub-backend", zeroed) {
		t.Fatal("rails-setup going from inherit to [] must move the attach stamp")
	}
}

// WIRING, pivot path: the parity test above compares resolver outputs; this
// proves ComposeForPivot's unit loop actually WRITES each unit's resolved set,
// not the module-wide one. Observable: sysroot/etc/systemd/system/<unit>.d/
// ambient-capabilities.conf (WriteAmbientCapabilityDropInAt), which is
// written only for a non-empty set.
func TestRenderPivotUnits_WritesEachUnitsResolvedAmbientSet(t *testing.T) {
	sysroot := t.TempDir()
	rec := &mount.RecorderRunner{}
	r := newPivotReconciler(rec)

	mf := hubBackendLike(t)
	stack := mount.ModuleStack{{ID: mf.ID, Priority: 1}}
	r.renderPivotUnits(context.Background(), sysroot, stack, map[string]*manifest.Manifest{mf.ID: mf}, &BootComposedBreadcrumb{})

	ambient := func(svc string) (string, bool) {
		b, err := os.ReadFile(filepath.Join(sysroot, "etc", "systemd", "system",
			lifecycle.UnitName(mf.ID, svc)+".d", "ambient-capabilities.conf"))
		return string(b), err == nil
	}
	if body, ok := ambient("rails-setup"); !ok ||
		!strings.Contains(body, "CAP_CHOWN") || !strings.Contains(body, "CAP_FOWNER") || !strings.Contains(body, "CAP_DAC_OVERRIDE") {
		t.Errorf("rails-setup (no key) must be granted the whole ceiling, got ok=%v body=%q", ok, body)
	}
	if body, ok := ambient("rails"); ok {
		t.Errorf("rails declares [] and must get NO ambient grant, got %q", body)
	}
	if body, ok := ambient("chowner"); !ok || !strings.Contains(body, "CAP_CHOWN") || strings.Contains(body, "CAP_FOWNER") {
		t.Errorf("chowner declares [CAP_CHOWN] and must get exactly that, got ok=%v body=%q", ok, body)
	}
}

// And a module whose service asks for more than the ceiling is refused on the
// pivot path — its services are not enabled at all.
func TestRenderPivotUnits_RefusesAModuleWithAServiceOverTheCeiling(t *testing.T) {
	sysroot := t.TempDir()
	rec := &mount.RecorderRunner{}
	r := newPivotReconciler(rec)

	var mf manifest.Manifest
	if err := json.Unmarshal([]byte(`{
	  "id": "greedy", "name": "greedy",
	  "config": {"security": {"capabilities": ["CAP_CHOWN"]}},
	  "services": [{"name": "app", "start_command": "/bin/true", "capabilities": ["CAP_SYS_ADMIN"]}]
	}`), &mf); err != nil {
		t.Fatal(err)
	}
	stack := mount.ModuleStack{{ID: mf.ID, Priority: 1}}
	r.renderPivotUnits(context.Background(), sysroot, stack, map[string]*manifest.Manifest{mf.ID: &mf}, &BootComposedBreadcrumb{})

	if unitEnabled(t, sysroot, rec, "greedy") {
		t.Error("a module with a service capability outside its ceiling must not be enabled post-pivot")
	}
}

// MIXED-VERSION SAFETY (review finding F1). A server that predates stage 1
// (IMP-074fcd68284f) — or runs it but has not yet republished a module; stage
// 1 ships no backfill — sends `svc.capabilities || []`: EVERY service arrives
// as [], whether its manifest declared [] or nothing. Read with presence
// semantics, that zeroes rails-setup, the root hub-worker units and vault
// (CAP_IPC_LOCK) — the 09-21 outage, fleet-wide, the moment a new agent meets
// an old payload. So a declared [] is honoured as ZERO only when the payload
// says its [] can be trusted: module-level `service_capabilities_presence:
// true`, which a presence-preserving server emits. Without it (LEGACY) both
// [] and null inherit the ceiling, and legacy can never be wider than today's
// module-wide behaviour.

// oldServerPayload is what a pre-stage-1 server sends for hub-backend, a
// hub-worker-shaped unit and vault: every service collapsed to [].
func oldServerPayload(t *testing.T, marker bool) *manifest.Manifest {
	t.Helper()
	presence := ""
	if marker {
		presence = `"service_capabilities_presence": true,`
	}
	var mf manifest.Manifest
	body := `{
	  "id": "hub-backend",` + presence + `
	  "config": {"security": {"capabilities": ["CAP_CHOWN", "CAP_FOWNER", "CAP_DAC_OVERRIDE", "CAP_IPC_LOCK"]}},
	  "services": [
	    {"name": "rails-setup", "start_command": "/x", "capabilities": []},
	    {"name": "rails", "start_command": "/x", "user": "powernode-rails", "capabilities": []},
	    {"name": "sidekiq", "start_command": "/x", "capabilities": []},
	    {"name": "vault", "start_command": "/x", "capabilities": []},
	    {"name": "narrow", "start_command": "/x", "capabilities": ["CAP_CHOWN"]}
	  ]
	}`
	if err := json.Unmarshal([]byte(body), &mf); err != nil {
		t.Fatalf("decode fixture: %v", err)
	}
	return &mf
}

func TestUnitCapabilities_LegacyPayloadWithoutMarkerInheritsTheCeiling(t *testing.T) {
	mf := oldServerPayload(t, false)
	writes, err := attachCapabilityWrites(mf, buildPolicy(mf))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	got := capsByUnit(t, writes)
	ceiling := []string{"CAP_CHOWN", "CAP_DAC_OVERRIDE", "CAP_FOWNER", "CAP_IPC_LOCK"}
	for _, svc := range []string{"rails-setup", "rails", "sidekiq", "vault"} {
		if unit := "powernode-hub-backend-" + svc + ".service"; !reflect.DeepEqual(got[unit], ceiling) {
			t.Errorf("legacy payload: %s must inherit the whole ceiling %v (today's module-wide behaviour), got %v",
				svc, ceiling, got[unit])
		}
	}
	// A non-empty list is still honoured as a subset: never wider than today.
	if unit := "powernode-hub-backend-narrow.service"; !reflect.DeepEqual(got[unit], []string{"CAP_CHOWN"}) {
		t.Errorf("legacy payload: a non-empty declared set is still that unit's exact set, got %v", got[unit])
	}
}

func TestUnitCapabilities_MarkedPayloadHonoursExplicitEmptyAsZero(t *testing.T) {
	mf := oldServerPayload(t, true)
	writes, err := attachCapabilityWrites(mf, buildPolicy(mf))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got := capsByUnit(t, writes)["powernode-hub-backend-rails.service"]; len(got) != 0 {
		t.Fatalf("with service_capabilities_presence, rails' [] must be ZERO, got %v", got)
	}
}

// The marker must survive the manifest cache (writeCache / LoadFromDisk), or a
// cache-served reconcile would silently fall back to legacy.
func TestManifest_PresenceMarkerSurvivesJSONRoundTrip(t *testing.T) {
	for _, marker := range []bool{true, false} {
		mf := oldServerPayload(t, marker)
		body, err := json.Marshal(mf)
		if err != nil {
			t.Fatal(err)
		}
		var back manifest.Manifest
		if err := json.Unmarshal(body, &back); err != nil {
			t.Fatal(err)
		}
		if back.ServiceCapabilitiesPresence != marker {
			t.Errorf("marker %v did not survive the round trip: got %v", marker, back.ServiceCapabilitiesPresence)
		}
	}
}

func TestUnitCapabilities_ParityHoldsInBothModes(t *testing.T) {
	for _, marker := range []bool{false, true} {
		mf := oldServerPayload(t, marker)
		policy := buildPolicy(mf)
		attach, aerr := attachCapabilityWrites(mf, policy)
		compose, cerr := composeCapabilityWrites(mf.ID, mf, policy)
		if aerr != nil || cerr != nil {
			t.Fatalf("marker=%v: attach err %v, compose err %v", marker, aerr, cerr)
		}
		if a, c := capsByUnit(t, attach), capsByUnit(t, compose); !reflect.DeepEqual(a, c) {
			t.Fatalf("marker=%v: reconcile and compose disagree:\n reconcile %v\n compose   %v", marker, a, c)
		}
	}
}

// WIRING, cloud-init path (review finding P2). The parity test compares two
// views of one resolver, so it cannot fail if attachModule's own drop-in loop
// ignores that resolver. This drives the real attachModule — stub puller,
// recorder runner, drop-in root redirected to a temp dir — and reads back the
// capabilities.conf each unit actually got.
func TestAttachModule_WritesEachUnitsResolvedCapabilityDropIn(t *testing.T) {
	dropIns := t.TempDir()
	t.Cleanup(security.SetSystemdDropInRootForTest(dropIns))

	layout := mount.DefaultLayout()
	layout.Root = t.TempDir()
	layout = layout.Resolve()
	r := &Reconciler{cfg: ReconcilerConfig{
		Puller:      &stubPuller{cacheDir: layout.ModulesCacheRoot},
		Verifier:    verify.AlwaysOK{},
		MountRunner: &mount.RecorderRunner{},
		Layout:      layout,
		OnError:     func(string, error) {},
	}}

	mf := hubBackendLike(t)
	if err := r.attachModule(context.Background(), mount.Module{ID: mf.ID, Digest: "d1", Priority: 1}, mf); err != nil {
		t.Fatalf("attachModule: %v", err)
	}

	capConf := func(svc string) string {
		b, err := os.ReadFile(filepath.Join(dropIns, lifecycle.UnitName(mf.ID, svc)+".d", "capabilities.conf"))
		if err != nil {
			t.Fatalf("read %s capabilities.conf: %v", svc, err)
		}
		return string(b)
	}
	directive := func(body, key string) []string {
		var vals []string
		for _, line := range strings.Split(body, "\n") {
			if v, ok := strings.CutPrefix(line, key+"="); ok && v != "" {
				vals = append(vals, v)
			}
		}
		return vals
	}

	if b := capConf("rails"); len(directive(b, "CapabilityBoundingSet")) != 0 || len(directive(b, "AmbientCapabilities")) != 0 {
		t.Errorf("rails declares [] and must get EMPTY bounding and ambient sets, got:\n%s", b)
	}
	if got := directive(capConf("rails-setup"), "CapabilityBoundingSet"); !reflect.DeepEqual(got, []string{"CAP_CHOWN CAP_DAC_OVERRIDE CAP_FOWNER"}) {
		t.Errorf("rails-setup (no key) must get the whole ceiling, got bounding %v", got)
	}
	if got := directive(capConf("chowner"), "CapabilityBoundingSet"); !reflect.DeepEqual(got, []string{"CAP_CHOWN"}) {
		t.Errorf("chowner declares [CAP_CHOWN] and must get exactly that, got bounding %v", got)
	}
}

// UPGRADE SAFETY (review finding P3). A manifest cache or boot-LKG snapshot
// written by the PREVIOUS agent re-marshalled Service.Capabilities as an
// omitempty []string, so a declared [] is simply gone from those bytes, and
// they carry no service_capabilities_presence marker (that agent never knew
// it). Decoded by this agent, such bytes are LEGACY: every unit inherits the
// ceiling — exactly what the previous agent applied, never wider — until the
// next fetch from a presence-marking server replaces them. That fetch is what
// finally zeroes rails; the first post-upgrade boot off an old LKG does not,
// and must not break rails-setup trying. bootLKGSchemaVersion is deliberately
// NOT bumped: the old bytes decode, and decode safely.
func TestUnitCapabilities_OldAgentLKGBytesAreLegacyUntilRefetched(t *testing.T) {
	oldAgentBytes := json.RawMessage(`{
	  "id": "hub-backend", "name": "hub-backend", "priority": 1, "effective_priority": 1,
	  "config": {"security": {"capabilities": ["CAP_CHOWN", "CAP_FOWNER", "CAP_DAC_OVERRIDE"]}},
	  "services": [
	    {"name": "rails-setup", "start_command": "/x"},
	    {"name": "rails", "start_command": "/x", "user": "powernode-rails"}
	  ]
	}`)
	lkg := &BootLKG{Modules: []LKGModule{{ID: "hub-backend", HasDataFile: true, Digest: "d1", Manifest: oldAgentBytes}}}
	_, manifests, err := lkg.ToComposeInputs()
	if err != nil {
		t.Fatalf("ToComposeInputs: %v", err)
	}
	mf := manifests["hub-backend"]
	writes, err := composeCapabilityWrites("hub-backend", mf, buildPolicy(mf))
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	ceiling := []string{"CAP_CHOWN", "CAP_DAC_OVERRIDE", "CAP_FOWNER"}
	for unit, got := range capsByUnit(t, writes) {
		if !reflect.DeepEqual(got, ceiling) {
			t.Errorf("old-agent LKG bytes: %s must inherit the ceiling (today's behaviour), got %v", unit, got)
		}
	}

	// The refetch from a presence-marking server corrects it.
	fresh := hubBackendLike(t)
	writes, err = attachCapabilityWrites(fresh, buildPolicy(fresh))
	if err != nil {
		t.Fatalf("resolve fresh: %v", err)
	}
	if got := capsByUnit(t, writes)["powernode-hub-backend-rails.service"]; len(got) != 0 {
		t.Errorf("after a refetch from a presence-marking server rails must be ZERO, got %v", got)
	}
}
