package runtime

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// IMP-87ce46b9a1aa — the timezone rides the same per-node envelope the hostname
// does (GET node_api/modules). It is persisted under /persist, validated by shape
// BEFORE it is persisted, and re-rendered into /etc by every reconcile tick and by
// the pre-pivot compose, so it survives the reboot that reverts a hand-set zone.

func redirectTimezonePath(t *testing.T) string {
	t.Helper()
	orig := assignedTimezonePath
	assignedTimezonePath = filepath.Join(t.TempDir(), "timezone")
	t.Cleanup(func() { assignedTimezonePath = orig })
	return assignedTimezonePath
}

func TestDesiredTimezone_PersistedPrecedenceAndNeverInvented(t *testing.T) {
	redirectTimezonePath(t)

	if got := desiredTimezone(); got != "" {
		t.Fatalf("no declared timezone: want \"\", got %q", got)
	}

	persistAssignedTimezone("America/Anchorage")
	if got := desiredTimezone(); got != "America/Anchorage" {
		t.Fatalf("persisted: got %q", got)
	}

	// A blank push does not clobber the stored value (absence is not a clearance).
	persistAssignedTimezone("   ")
	if got := desiredTimezone(); got != "America/Anchorage" {
		t.Fatalf("a blank push must be a no-op, got %q", got)
	}

	persistAssignedTimezone("Europe/Berlin")
	if got := desiredTimezone(); got != "Europe/Berlin" {
		t.Fatalf("an update overwrites, got %q", got)
	}
}

func TestPersistAssignedTimezone_RefusesAMalformedNameBeforeItIsStored(t *testing.T) {
	path := redirectTimezonePath(t)
	persistAssignedTimezone("America/Anchorage")

	for _, bad := range []string{"../../etc/passwd", "/etc/passwd", "UTC\nx", "a b", "a;b", strings.Repeat("A", 80)} {
		persistAssignedTimezone(bad)
		if got := desiredTimezone(); got != "America/Anchorage" {
			t.Fatalf("a malformed value (%q) must not replace the stored zone, got %q", bad, got)
		}
	}
	if raw, _ := os.ReadFile(path); strings.TrimSpace(string(raw)) != "America/Anchorage" {
		t.Fatalf("stored file changed: %q", raw)
	}
}

func TestFetchAssignedModules_PersistsTheEnvelopeTimezone(t *testing.T) {
	redirectTimezonePath(t)
	redirectHostnamePath(t)
	client := &stubModulesClient{responses: map[string]string{
		"/api/v1/system/node_api/modules": `{"success":true,"data":{"modules":[],"count":0,"hostname":"n1","timezone":"America/Anchorage"}}`,
	}}

	if _, _, err := FetchAssignedModules(context.Background(), client); err != nil {
		t.Fatal(err)
	}

	if got := desiredTimezone(); got != "America/Anchorage" {
		t.Fatalf("the envelope timezone must be persisted, got %q", got)
	}
}

func redirectHostnamePath(t *testing.T) {
	t.Helper()
	orig := assignedHostnamePath
	assignedHostnamePath = filepath.Join(t.TempDir(), "hostname")
	t.Cleanup(func() { assignedHostnamePath = orig })
}

// The live reconcile re-asserts the declared zone every tick through the same
// indirection the hostname writer uses, and a failed render is reported without
// failing the pass.
func TestRunOnce_RendersTheDeclaredTimezoneAndReportsAFailure(t *testing.T) {
	redirectTimezonePath(t)
	persistAssignedTimezone("America/Anchorage")

	type call struct{ root, name string }
	var calls []call
	var applyErr error
	orig := applyTimezone
	applyTimezone = func(root, name string) (bool, error) {
		calls = append(calls, call{root, name})
		return applyErr == nil, applyErr
	}
	t.Cleanup(func() { applyTimezone = orig })

	r, _, _, _, _, _, _ := upgradeTestReconciler(t)
	var errs []string
	r.cfg.OnError = func(stage string, err error) { errs = append(errs, stage+": "+err.Error()) }

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}
	if len(calls) == 0 || calls[len(calls)-1] != (call{"", "America/Anchorage"}) {
		t.Fatalf("the live root must be rendered with the declared zone, calls=%v", calls)
	}

	applyErr = errors.New("zone not in image")
	errs = nil
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("a failed timezone render must not fail the pass: %v", err)
	}
	if !convergenceFailuresContain(errs, "reconciler:timezone_write") {
		t.Fatalf("a failed render must be reported as reconciler:timezone_write, got %v", errs)
	}
}

func TestRunOnce_NoTimezoneDeclaredRendersNothing(t *testing.T) {
	redirectTimezonePath(t)

	called := false
	orig := applyTimezone
	applyTimezone = func(string, string) (bool, error) { called = true; return false, nil }
	t.Cleanup(func() { applyTimezone = orig })

	r, _, _, _, _, _, _ := upgradeTestReconciler(t)
	r.cfg.OnError = func(string, error) {}
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatal(err)
	}
	if called {
		t.Fatalf("with no declared timezone the agent must never render one")
	}
}

// The pre-pivot compose renders the declared zone into the composed union, so the
// switch_root'd system boots in it rather than in UTC.
func TestRenderTimezoneInto_ComposedUnion(t *testing.T) {
	redirectTimezonePath(t)
	sysroot := t.TempDir()
	zone := filepath.Join(sysroot, "usr", "share", "zoneinfo", "America", "Anchorage")
	if err := os.MkdirAll(filepath.Dir(zone), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(zone, []byte("TZif2"+strings.Repeat("\x00", 40)), 0o644); err != nil {
		t.Fatal(err)
	}
	var errs []string
	r := &Reconciler{}
	r.cfg.OnError = func(stage string, err error) { errs = append(errs, stage+": "+err.Error()) }

	r.renderTimezoneInto(sysroot) // nothing declared: nothing rendered
	if _, err := os.Lstat(filepath.Join(sysroot, "etc", "localtime")); !os.IsNotExist(err) {
		t.Fatalf("nothing declared, nothing rendered")
	}

	persistAssignedTimezone("America/Anchorage")
	r.renderTimezoneInto(sysroot)
	target, err := os.Readlink(filepath.Join(sysroot, "etc", "localtime"))
	if err != nil || target != "../usr/share/zoneinfo/America/Anchorage" {
		t.Fatalf("composed union localtime = %q, %v (errs %v)", target, err, errs)
	}

	// A declared zone the image does not carry is reported, never fatal.
	persistAssignedTimezone("Nowhere/Land")
	r.renderTimezoneInto(sysroot)
	if !convergenceFailuresContain(errs, "compose:timezone_write") {
		t.Fatalf("a zone the image lacks must be reported as compose:timezone_write, got %v", errs)
	}
}
