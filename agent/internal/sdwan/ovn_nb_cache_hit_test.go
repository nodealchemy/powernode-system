// ovn_nb_cache_hit_test.go — IMP-57e9a90598ee: the CacheHit discriminator on
// ObservedOvnNbState.
//
// The short-circuit branch of ShellOvnNbApplier.Apply fabricates a
// fully-applied observation — fresh LastReplayAt included — WITHOUT executing
// anything. That is fine as an optimization, but the platform-side
// DeploymentReconciler must be able to tell a real replay from a cache
// re-assertion, so the cached branch must say so. The invariant these tests
// pin: CacheHit is true on exactly the invocations that executed nothing, and
// the cache is only ever populated by a completed successful replay (a failure
// never seeds it), so any full-success observation — cache-hit or not —
// implies a real replay happened against that endpoint+plan in this process.
package sdwan

import (
	"context"
	"os"
	"strings"
	"testing"
)

func countCalls(t *testing.T, logPath string) int {
	t.Helper()
	data, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("read call log: %v", err)
	}
	trimmed := strings.TrimSpace(string(data))
	if trimmed == "" {
		return 0
	}
	return len(strings.Split(trimmed, "\n"))
}

func cachePlan() *OvnNbPlan {
	return &OvnNbPlan{
		DeploymentID: "dep-1",
		NbDbEndpoint: "tcp:10.0.0.1:6641",
		Plan: []OvnNbCommand{
			{Cmd: "ls-add", Args: []string{"ls-app"}},
		},
		CompiledAt: "2026-08-20T00:00:00Z",
	}
}

func TestOvnNbApplier_CacheHitFlagsTheShortCircuit(t *testing.T) {
	nbctlBin, logPath, _ := newNbRecorderBin(t)
	a := &ShellOvnNbApplier{OvnNbctlBin: nbctlBin}

	first, err := a.Apply(context.Background(), cachePlan())
	if err != nil {
		t.Fatalf("first apply: %v", err)
	}
	if first.CacheHit {
		t.Fatalf("first apply executed the plan; CacheHit must be false")
	}
	if got := countCalls(t, logPath); got != 1 {
		t.Fatalf("first apply: want 1 exec, got %d", got)
	}

	second, err := a.Apply(context.Background(), cachePlan())
	if err != nil {
		t.Fatalf("second apply: %v", err)
	}
	if !second.CacheHit {
		t.Fatalf("byte-identical second apply short-circuited; CacheHit must be true")
	}
	if second.AppliedCommands != 1 || second.PlanCommands != 1 {
		t.Fatalf("cached observation must re-assert the full success, got %+v", second)
	}
	if got := countCalls(t, logPath); got != 1 {
		t.Fatalf("second apply must not exec; want 1 total, got %d", got)
	}
}

func TestOvnNbApplier_FailureNeverSeedsTheCache(t *testing.T) {
	nbctlBin, logPath, failPath := newNbRecorderBin(t)
	a := &ShellOvnNbApplier{OvnNbctlBin: nbctlBin}

	if err := os.WriteFile(failPath, []byte("ls-add"), 0o644); err != nil {
		t.Fatalf("arm failon: %v", err)
	}
	obs, err := a.Apply(context.Background(), cachePlan())
	if err == nil {
		t.Fatalf("expected the armed failure")
	}
	if obs == nil || obs.CacheHit {
		t.Fatalf("a failed replay is an executed observation, never a cache hit: %+v", obs)
	}

	if err := os.WriteFile(failPath, []byte(""), 0o644); err != nil {
		t.Fatalf("disarm failon: %v", err)
	}
	recovered, err := a.Apply(context.Background(), cachePlan())
	if err != nil {
		t.Fatalf("recovery apply: %v", err)
	}
	if recovered.CacheHit {
		t.Fatalf("post-failure success must be a real replay (cache was never seeded)")
	}
	if got := countCalls(t, logPath); got != 2 {
		t.Fatalf("want 2 execs (failed + recovered), got %d", got)
	}
}
