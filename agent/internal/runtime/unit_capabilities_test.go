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
// IMP-caef5c00d63f phase 2: they now WRITE it identically too — attachModule's
// WriteCapabilityDropIn and ComposeForPivot's WriteCapabilityDropInAt render
// the SAME drop-in body (renderCapabilityDropInBody), resetting
// CapabilityBoundingSet AND AmbientCapabilities to the resolved set, always
// (including an explicitly-empty allow list). See
// TestRenderPivotUnits_WritesEachUnitsResolvedCapabilityDropIn and
// TestComposeAndAttach_WriteByteIdenticalCapabilityDropIns for the drop-in-bytes
// half of this parity; this test pins the resolver half.
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
// capabilities.conf (WriteCapabilityDropInAt), written for EVERY unit
// including one that resolves to empty (IMP-caef5c00d63f phase 2 — the drop-in
// is no longer skipped for an empty allow list; an absent drop-in would leave
// the unit at systemd's full default bounding set instead of the strictest
// posture).
func TestRenderPivotUnits_WritesEachUnitsResolvedCapabilityDropIn(t *testing.T) {
	sysroot := t.TempDir()
	rec := &mount.RecorderRunner{}
	r := newPivotReconciler(rec)

	mf := hubBackendLike(t)
	stack := mount.ModuleStack{{ID: mf.ID, Priority: 1}}
	r.renderPivotUnits(context.Background(), sysroot, stack, map[string]*manifest.Manifest{mf.ID: mf}, &BootComposedBreadcrumb{})

	capConf := func(svc string) (string, bool) {
		b, err := os.ReadFile(filepath.Join(sysroot, "etc", "systemd", "system",
			lifecycle.UnitName(mf.ID, svc)+".d", "capabilities.conf"))
		return string(b), err == nil
	}
	if body, ok := capConf("rails-setup"); !ok ||
		!strings.Contains(body, "CapabilityBoundingSet=CAP_CHOWN CAP_DAC_OVERRIDE CAP_FOWNER") ||
		!strings.Contains(body, "AmbientCapabilities=CAP_CHOWN CAP_DAC_OVERRIDE CAP_FOWNER") {
		t.Errorf("rails-setup (no key) must be granted the whole ceiling in BOTH sets, got ok=%v body=%q", ok, body)
	}
	if body, ok := capConf("rails"); !ok || strings.Contains(body, "CAP_") {
		t.Errorf("rails declares [] and must get an EXPLICITLY EMPTY bounding+ambient drop-in (not a missing one), got ok=%v body=%q", ok, body)
	}
	if body, ok := capConf("chowner"); !ok ||
		!strings.Contains(body, "CapabilityBoundingSet=CAP_CHOWN\n") || strings.Contains(body, "CAP_FOWNER") {
		t.Errorf("chowner declares [CAP_CHOWN] and must get exactly that in both sets, got ok=%v body=%q", ok, body)
	}
}

// BYTE PARITY (IMP-caef5c00d63f phase 2). The two tests above each drive one
// path; this drives BOTH against the SAME manifest and asserts the rendered
// capabilities.conf bytes are IDENTICAL per unit — the strongest form of "the
// pivot-compose path produces the same per-unit capability policy as the
// running reconciler", stronger than comparing resolver output (which could
// pass while the two writers still rendered different bytes).
func TestComposeAndAttach_WriteByteIdenticalCapabilityDropIns(t *testing.T) {
	mf := hubBackendLike(t)

	// attachModule's view: systemdDropInRoot redirected to a temp dir.
	attachRoot := t.TempDir()
	t.Cleanup(security.SetSystemdDropInRootForTest(attachRoot))
	layout := mount.DefaultLayout()
	layout.Root = t.TempDir()
	layout = layout.Resolve()
	ar := &Reconciler{cfg: ReconcilerConfig{
		Puller:      &stubPuller{cacheDir: layout.ModulesCacheRoot},
		Verifier:    verify.AlwaysOK{},
		MountRunner: &mount.RecorderRunner{},
		Layout:      layout,
		OnError:     func(string, error) {},
	}}
	if err := ar.attachModule(context.Background(), mount.Module{ID: mf.ID, Digest: "d1", Priority: 1}, mf); err != nil {
		t.Fatalf("attachModule: %v", err)
	}

	// ComposeForPivot's view: an explicit sysroot.
	sysroot := t.TempDir()
	cr := newPivotReconciler(&mount.RecorderRunner{})
	stack := mount.ModuleStack{{ID: mf.ID, Priority: 1}}
	cr.renderPivotUnits(context.Background(), sysroot, stack, map[string]*manifest.Manifest{mf.ID: mf}, &BootComposedBreadcrumb{})

	for _, svc := range []string{"rails-setup", "rails", "chowner"} {
		unit := lifecycle.UnitName(mf.ID, svc)
		attached, err := os.ReadFile(filepath.Join(attachRoot, unit+".d", "capabilities.conf"))
		if err != nil {
			t.Fatalf("%s: read attach drop-in: %v", svc, err)
		}
		composed, err := os.ReadFile(filepath.Join(sysroot, "etc", "systemd", "system", unit+".d", "capabilities.conf"))
		if err != nil {
			t.Fatalf("%s: read compose drop-in: %v", svc, err)
		}
		if string(attached) != string(composed) {
			t.Errorf("%s: attach and compose drop-ins are NOT byte-identical:\nattach=%q\ncompose=%q", svc, attached, composed)
		}
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

// CLAUDE-TMUX / GROK-CLI CEILING FIX (operator decision, IMP-caef5c00d63f
// phase 2 follow-up). Both modules' `credential` unit chowns/chmods root-
// created files to the session user and (claude-tmux only) writes into the
// session user's own home directory — established by reading each script
// line by line and verified empirically (systemd-run
// --property=CapabilityBoundingSet=) to need exactly CAP_CHOWN,
// CAP_DAC_OVERRIDE and CAP_FOWNER, no more and no less. This fixture mirrors
// claude-tmux's real manifest shape post-fix: ceiling raised to that set,
// `credential` declared with that exact set (not by inheritance), and the
// OTHER service in the module (`claude`, the tmux session, a non-root
// already-owning process) explicitly declared [] so it can never silently
// inherit CHOWN/DAC_OVERRIDE/FOWNER by omission. grok-cli has the identical
// ceiling and a single service (no second unit to leak to), so it is not
// separately fixtured here — the resolver logic under test is unchanged
// between the one-service and two-service case; this is the one worth
// pinning because a service silently inheriting the ceiling by omission is
// exactly the defect class IMP-caef5c00d63f phase 1 was built to close.
func TestUnitCapabilities_ClaudeTmuxShapedManifestGrantsOnlyCredential(t *testing.T) {
	var mf manifest.Manifest
	body := `{
	  "id": "claude-tmux", "service_capabilities_presence": true,
	  "config": {"security": {"capabilities": ["CAP_CHOWN", "CAP_DAC_OVERRIDE", "CAP_FOWNER"]}},
	  "services": [
	    {"name": "credential", "start_command": "/usr/local/bin/claude-tmux-fetch-credential.sh",
	     "capabilities": ["CAP_CHOWN", "CAP_DAC_OVERRIDE", "CAP_FOWNER"]},
	    {"name": "claude", "start_command": "/usr/local/bin/claude-tmux-start.sh", "user": "pnadmin",
	     "capabilities": []}
	  ]
	}`
	if err := json.Unmarshal([]byte(body), &mf); err != nil {
		t.Fatalf("decode fixture: %v", err)
	}
	policy := buildPolicy(&mf)

	for _, resolve := range []struct {
		name string
		fn   func() ([]security.UnitCapabilities, error)
	}{
		{"attach", func() ([]security.UnitCapabilities, error) { return attachCapabilityWrites(&mf, policy) }},
		{"compose", func() ([]security.UnitCapabilities, error) { return composeCapabilityWrites(mf.ID, &mf, policy) }},
	} {
		t.Run(resolve.name, func(t *testing.T) {
			writes, err := resolve.fn()
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			got := capsByUnit(t, writes)
			want := map[string][]string{
				"powernode-claude-tmux-credential.service": {"CAP_CHOWN", "CAP_DAC_OVERRIDE", "CAP_FOWNER"},
				"powernode-claude-tmux-claude.service":     {},
			}
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("resolved per-unit sets:\n got  %v\n want %v — the session unit must get EMPTY ambient+bounding, never the credential-only ceiling", got, want)
			}
		})
	}
}

// QGA FULL-CEILING FIX (operator decision, IMP-caef5c00d63f phase 2 review
// round — REPLACES the reverted `privileged: true`; see that manifest's own
// security block comment for why). Mirrors qemu-guest-agent's real manifest
// shape post-fix: ceiling = every capability security.KnownCapabilities
// recognizes (41 entries — confirmed equal to the "ALL 41" bounding set
// already observed live on ops-hub before this whole phase touched
// anything), `qga` (the module's only service) left WITHOUT a per-service
// key so it inherits the whole thing on BOTH paths. This is deliberately
// NOT gated behind privileged: true, so it carries no allowlist dependency.
func TestUnitCapabilities_QgaShapedManifestGrantsTheFullKnownSet(t *testing.T) {
	fullSet := make([]string, 0, len(security.KnownCapabilities))
	for name := range security.KnownCapabilities {
		fullSet = append(fullSet, name)
	}
	sort.Strings(fullSet)
	if len(fullSet) != 41 {
		t.Fatalf("security.KnownCapabilities has %d entries, expected 41 (the live-observed full bounding set) — "+
			"qga's manifest was written assuming this count; update both together if it ever changes", len(fullSet))
	}

	ceilingJSON, err := json.Marshal(fullSet)
	if err != nil {
		t.Fatal(err)
	}
	var mf manifest.Manifest
	body := `{
	  "id": "qemu-guest-agent", "service_capabilities_presence": true,
	  "config": {"security": {"capabilities": ` + string(ceilingJSON) + `}},
	  "services": [{"name": "qga", "start_command": "/usr/sbin/qemu-ga -t /run", "user": "root"}]
	}`
	if err := json.Unmarshal([]byte(body), &mf); err != nil {
		t.Fatalf("decode fixture: %v", err)
	}
	policy := buildPolicy(&mf)

	for _, resolve := range []struct {
		name string
		fn   func() ([]security.UnitCapabilities, error)
	}{
		{"attach", func() ([]security.UnitCapabilities, error) { return attachCapabilityWrites(&mf, policy) }},
		{"compose", func() ([]security.UnitCapabilities, error) { return composeCapabilityWrites(mf.ID, &mf, policy) }},
	} {
		t.Run(resolve.name, func(t *testing.T) {
			writes, err := resolve.fn()
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			got := capsByUnit(t, writes)["powernode-qemu-guest-agent-qga.service"]
			if !reflect.DeepEqual(got, fullSet) {
				t.Fatalf("qga must resolve to the FULL known capability set (no per-service key -> inherits the ceiling):\n got  %v\n want %v", got, fullSet)
			}
		})
	}
}

// PRIVILEGED MODULES OPT OUT ENTIRELY (IMP-caef5c00d63f phase 2 follow-up).
// Confirms neither path writes ANY capabilities.conf for a privileged
// module's unit — not an empty/strictest one, none at all — so a privileged
// module genuinely keeps systemd's full default bounding set on BOTH the
// reconcile and the pivot-compose path, exactly like it did before
// IMP-caef5c00d63f phase 2 ever touched non-privileged units.
//
// Uses a SYNTHETIC privileged module ("priv-mod"), not qemu-guest-agent:
// qga was reverted to non-privileged (see that manifest's own comment) after
// a live reviewer check found `privileged: true` refused on ops-hub, whose
// account allowlist (privileged_module_ids) does not name it — dev-cell is
// the only module actually privileged on this tree today, and it IS on that
// allowlist. Both subtests here APPROVE the synthetic module on its
// respective path's real gate (a frozen, approving breadcrumb for compose;
// a populated privilegedAllow for attach) rather than relying on either
// gate's "not yet armed" leniency arm — see
// TestPrivilegedModuleNotOnAllowlist_RefusedOnBothPaths for the refusal
// half, which is what actually would have caught the qga regression.
func TestPrivilegedModule_GetsNoCapabilityDropInOnEitherPath(t *testing.T) {
	mod, mf := privModule("priv-mod")

	t.Run("attach", func(t *testing.T) {
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
		r.privilegedAllow = []string{mf.ID} // operator-approved: attachModule enforces this allowlist unconditionally
		if err := r.attachModule(context.Background(), mod, mf); err != nil {
			t.Fatalf("attachModule: %v", err)
		}
		unit := lifecycle.UnitName(mf.ID, "app")
		if _, err := os.Stat(filepath.Join(dropIns, unit+".d", "capabilities.conf")); !os.IsNotExist(err) {
			t.Errorf("privileged module must get NO capabilities.conf on the attach path; stat err=%v", err)
		}
	})

	t.Run("compose", func(t *testing.T) {
		sysroot := t.TempDir()
		rec := &mount.RecorderRunner{}
		r := newPivotReconciler(rec)
		stack := mount.ModuleStack{{ID: mf.ID, Priority: 1}}
		// FROZEN + approving breadcrumb (real production shape once the
		// allowlist field is armed), not an empty/unfrozen one — an
		// unfrozen breadcrumb enables the module via the gate's OWN
		// leniency arm regardless of approval, which cannot distinguish
		// "approved" from "not yet checked" (the exact gap that hid the
		// qga regression).
		bc := &BootComposedBreadcrumb{PrivilegedAllowlistFrozen: true, PrivilegedModuleIDs: []string{mf.ID}}
		r.renderPivotUnits(context.Background(), sysroot, stack, map[string]*manifest.Manifest{mf.ID: mf}, bc)
		if !unitEnabled(t, sysroot, rec, mf.ID) {
			t.Fatal("the approved module must actually be enabled — otherwise the drop-in absence below is vacuous")
		}
		unit := lifecycle.UnitName(mf.ID, "app")
		path := filepath.Join(sysroot, "etc", "systemd", "system", unit+".d", "capabilities.conf")
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Errorf("privileged module must get NO capabilities.conf on the compose path; stat err=%v", err)
		}
	})
}

// THE WIRING TEST THAT WOULD HAVE CAUGHT THE qga REGRESSION (review round,
// IMP-caef5c00d63f phase 2). A privileged module NOT on the operator's
// allowlist must be refused on BOTH paths, using each path's REAL
// production gate shape:
//   - compose: a FROZEN breadcrumb whose PrivilegedModuleIDs excludes the
//     module (mirrors TestRenderPivotUnits_FrozenAllowlistRefusesUnapproved,
//     restated here for the parity story: both paths must agree).
//   - attach: r.privilegedAllow populated but NOT containing the module
//     (attachModule's own gate has no "unfrozen skips" leniency arm at all —
//     it enforces unconditionally — so this only needs a non-empty,
//     non-matching allowlist, not an "unarmed" state).
//
// Both must refuse WITHOUT enabling the unit and WITHOUT writing any
// capabilities.conf — a half-refusal (unit disabled but a drop-in written
// anyway, or vice versa) would be its own inconsistency bug.
func TestPrivilegedModuleNotOnAllowlist_RefusedOnBothPaths(t *testing.T) {
	mod, mf := privModule("priv-unapproved")

	t.Run("attach", func(t *testing.T) {
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
		r.privilegedAllow = []string{"some-other-module"} // populated, but does NOT approve this module
		if err := r.attachModule(context.Background(), mod, mf); err == nil {
			t.Fatal("attachModule must refuse a privileged module absent from the allowlist")
		}
		unit := lifecycle.UnitName(mf.ID, "app")
		if _, err := os.Stat(filepath.Join(dropIns, unit+".d", "capabilities.conf")); !os.IsNotExist(err) {
			t.Errorf("a refused module must get NO capabilities.conf either; stat err=%v", err)
		}
	})

	t.Run("compose", func(t *testing.T) {
		sysroot := t.TempDir()
		rec := &mount.RecorderRunner{}
		r := newPivotReconciler(rec)
		stack := mount.ModuleStack{{ID: mf.ID, Priority: 1}}
		bc := &BootComposedBreadcrumb{PrivilegedAllowlistFrozen: true, PrivilegedModuleIDs: []string{"some-other-module"}}
		r.renderPivotUnits(context.Background(), sysroot, stack, map[string]*manifest.Manifest{mf.ID: mf}, bc)
		if unitEnabled(t, sysroot, rec, mf.ID) {
			t.Error("renderPivotUnits must refuse a privileged module absent from the allowlist")
		}
		unit := lifecycle.UnitName(mf.ID, "app")
		if _, err := os.Stat(filepath.Join(sysroot, "etc", "systemd", "system", unit+".d", "capabilities.conf")); !os.IsNotExist(err) {
			t.Errorf("a refused module must get NO capabilities.conf either; stat err=%v", err)
		}
	})
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
