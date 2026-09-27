package runtime

import (
	"context"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// modulesListWithPrivilegedAllow builds the /modules envelope with a
// controllable privileged_module_ids allowlist (X3's own test needs to
// REVOKE an approval between boots without touching the manifest itself, so
// the ordinary attach-stamp gate cannot see the change at all — only
// reconfirmConfinementIfNeeded's own fresh decideSecurityPolicyForAttach
// call does).
func modulesListWithPrivilegedAllow(allow []string) string {
	quoted := make([]string, len(allow))
	for i, a := range allow {
		quoted[i] = `"` + a + `"`
	}
	return fmt.Sprintf(`{
		"success": true,
		"data": {
			"modules": [{"id":"m1", "name":"app-mod", "priority":100, "effective_priority":100, "has_data_file":true}],
			"privileged_module_ids": [%s]
		}
	}`, strings.Join(quoted, ","))
}

func manifestFixturePrivileged(digest string) string {
	return fmt.Sprintf(`{
		"success": true,
		"data": {
			"id":"m1", "name":"app-mod",
			"priority":100, "effective_priority":100,
			"digest":"%s",
			"config": {"security": {"privileged": true}},
			"services": [
				{"name":"app", "start_command":"/bin/true", "restart_policy":"always"}
			]
		}
	}`, digest)
}

// TestReconfirmConfinement_ForcedFailureRetriesAndSkipsPull is X3+X4
// (IMP-caef5c00d63f round X, MEDIUM): a module the once-per-boot-composition
// recheck cannot cleanly resolve must leave ITS OWN ConfinementReconfirmed[id]
// UNSET (round Y: per-module, not one shared composition flag — see
// mount.State.ConfinementReconfirmed's own doc), so the NEXT tick under the
// SAME composition retries — not just once, silently dropped, the way
// marking the key BEFORE processing (the original W1-round design) did.
// Also pins X4's own narrowing: the recheck must never re-Pull the module's
// artifact.
//
// m1's manifest (privileged: true) never changes across any tick — the
// ordinary attach-stamp gate has nothing to see — only the operator's
// privileged_module_ids allowlist is revoked between boot A and boot B, a
// change reconfirmConfinementIfNeeded's own fresh decision must notice on
// its own.
func TestReconfirmConfinement_ForcedFailureRetriesAndSkipsPull(t *testing.T) {
	r, client, _, statePath, _, _ := newConfinementReattachReconciler(t)
	puller := r.cfg.Puller.(*stubPuller)

	origMode, origChecked := pivotAwareRootMode, pivotAwareRootModeChecked
	pivotAwareRootMode = func() lifecycle.RootMode { return lifecycle.RootModeNative }
	pivotAwareRootModeChecked = func() (lifecycle.RootMode, error) { return lifecycle.RootModeNative, nil }
	origBoot := currentBootID
	const bootA, bootB = "boot-a", "boot-b"
	boot := bootA
	currentBootID = func() string { return boot }
	t.Cleanup(func() {
		pivotAwareRootMode, pivotAwareRootModeChecked = origMode, origChecked
		currentBootID = origBoot
	})
	breadcrumbPath := filepath.Join(t.TempDir(), "boot-composed.json")
	t.Cleanup(SetBootBreadcrumbPathForTest(breadcrumbPath))
	composedAt := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	if err := WriteBreadcrumb(breadcrumbPath, &BootComposedBreadcrumb{BootID: bootA, ComposedAt: composedAt}); err != nil {
		t.Fatalf("WriteBreadcrumb (boot A): %v", err)
	}

	client.responses["/api/v1/system/node_api/modules"] = modulesListWithPrivilegedAllow([]string{"m1"})
	client.responses["/api/v1/system/node_api/modules/m1"] = manifestFixturePrivileged("abc123")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 1 (boot A, approved): %v", err)
	}
	pullsAfterTick1 := len(puller.calls)
	if pullsAfterTick1 == 0 {
		t.Fatal("precondition: expected at least one Pull for the fresh attach")
	}

	// NEW BOOT, approval REVOKED. The manifest (and therefore the attach
	// stamp) is byte-identical — only privileged_module_ids changed.
	boot = bootB
	if err := WriteBreadcrumb(breadcrumbPath, &BootComposedBreadcrumb{BootID: bootB, ComposedAt: composedAt.Add(time.Hour)}); err != nil {
		t.Fatalf("WriteBreadcrumb (boot B): %v", err)
	}
	client.responses["/api/v1/system/node_api/modules"] = modulesListWithPrivilegedAllow(nil)

	var onErrorsTick2 []string
	r.cfg.OnError = func(stage string, err error) { onErrorsTick2 = append(onErrorsTick2, stage+": "+err.Error()) }
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 2 (boot B, revoked): %v", err)
	}
	if !convergenceFailuresContain(onErrorsTick2, "reconciler:confinement_recheck_failed") {
		t.Errorf("X3 REGRESSION: expected the revoked-privileged module to fail the recheck on tick 2, got onErrors=%v", onErrorsTick2)
	}
	st, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	bootBKey := stateRebaseKeyOf(bootB, composedAt.Add(time.Hour))
	if st.ConfinementReconfirmed["m1"] == bootBKey {
		t.Error("X3 REGRESSION: m1 was marked reconfirmed despite failing its own recheck")
	}
	if got := len(puller.calls); got != pullsAfterTick1 {
		t.Errorf("X4 REGRESSION: expected NO additional Pull during the recheck, calls before=%d after=%d (%v)", pullsAfterTick1, got, puller.calls)
	}

	// TICK 3: still boot B, still revoked — must retry, not silently give up.
	var onErrorsTick3 []string
	r.cfg.OnError = func(stage string, err error) { onErrorsTick3 = append(onErrorsTick3, stage+": "+err.Error()) }
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 3 (boot B, still revoked): %v", err)
	}
	if !convergenceFailuresContain(onErrorsTick3, "reconciler:confinement_recheck_failed") {
		t.Errorf("X3 REGRESSION: expected the SAME composition to retry the failing module on tick 3, got onErrors=%v", onErrorsTick3)
	}
	if got := len(puller.calls); got != pullsAfterTick1 {
		t.Errorf("X4 REGRESSION: expected NO Pull on the retried recheck either, calls before=%d after=%d (%v)", pullsAfterTick1, got, puller.calls)
	}
}
