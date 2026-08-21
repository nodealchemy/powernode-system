// ovn_nb_prune_test.go — IMP-178a7e79fa0d: prune-side (removal
// convergence) tests for the OVN NB applier.
//
// The add-only applier meant deactivated/removed switches, ports, and
// ACLs lived on in the NB DB indefinitely. These tests pin the prune
// contract: the platform compiler ships a desired-set manifest with the
// plan, and the applier diffs `ovn-nbctl` list output against it,
// deleting ONLY rows the platform owns (scoped by the
// external_ids:powernode_ovn_deployment stamp the create path applies).
//
// Extends the recorder-shim pattern from ovn_nb_applier_test.go with a
// responses directory so the fake ovn-nbctl can ANSWER the read
// commands (find / lsp-list / acl-list) the prune pass issues. Each
// response file's first line is an argv substring to match; the rest is
// the stdout to emit.

package sdwan

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// newNbRespondingBin installs a fake `ovn-nbctl` that records argv like
// newNbRecorderBin and additionally serves canned stdout for read
// commands from respDir (first line = argv-substring needle, remainder
// = stdout).
func newNbRespondingBin(t *testing.T) (nbctlBin, logPath, failPath, respDir string) {
	t.Helper()

	dir := t.TempDir()
	nbctlBin = filepath.Join(dir, "ovn-nbctl")
	logPath = filepath.Join(dir, "calls")
	failPath = filepath.Join(dir, "failon")
	respDir = filepath.Join(dir, "responses")

	if err := os.WriteFile(logPath, []byte(""), 0o644); err != nil {
		t.Fatalf("seed log: %v", err)
	}
	if err := os.WriteFile(failPath, []byte(""), 0o644); err != nil {
		t.Fatalf("seed failon: %v", err)
	}
	if err := os.MkdirAll(respDir, 0o755); err != nil {
		t.Fatalf("mkdir responses: %v", err)
	}

	script := fmt.Sprintf(`#!/usr/bin/env bash
echo "$*" >> %q
needle=$(cat %q)
if [ -n "$needle" ]; then
    case "$*" in
        *"$needle"*)
            echo "ovn-nbctl: simulated failure for $needle" >&2
            exit 1
            ;;
    esac
fi
for f in %q/*; do
    [ -e "$f" ] || continue
    n=$(head -n1 "$f")
    case "$*" in
        *"$n"*)
            tail -n +2 "$f"
            exit 0
            ;;
    esac
done
exit 0
`, logPath, failPath, respDir)

	if err := os.WriteFile(nbctlBin, []byte(script), 0o755); err != nil {
		t.Fatalf("write ovn-nbctl shim: %v", err)
	}
	return
}

func nbAddResponse(t *testing.T, respDir, slug, needle, stdout string) {
	t.Helper()
	body := needle + "\n" + stdout
	if err := os.WriteFile(filepath.Join(respDir, slug), []byte(body), 0o644); err != nil {
		t.Fatalf("write response %s: %v", slug, err)
	}
}

func skipUnlessPosix(t *testing.T) {
	t.Helper()
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("recorder shim assumes POSIX shell")
	}
}

// prunePlan builds a plan whose desired set keeps switch "sw-keep" with
// port "p-keep" and one narrow allow ACL. The NB DB fixtures in each
// test then add extra (retracted) rows the applier must prune.
func prunePlan() *OvnNbPlan {
	return &OvnNbPlan{
		DeploymentID: "dep-123",
		NbDbEndpoint: "tcp:10.0.0.1:6641",
		CompiledAt:   "2026-08-21T00:00:00Z",
		Plan: []OvnNbCommand{
			{Cmd: "ls-add", Args: []string{"sw-keep"}},
			{Cmd: "set", Args: []string{"Logical_Switch", "sw-keep", "external_ids:powernode_ovn_deployment=dep-123"}},
			{Cmd: "lsp-add", Args: []string{"sw-keep", "p-keep"}},
			{Cmd: "lsp-set-addresses", Args: []string{"p-keep", "02:11:22:33:44:55 10.0.0.5"}},
			{Cmd: "acl-add", Args: []string{"sw-keep", "to-lport", "900", "ip4.src == 10.9.0.0/24", "allow"}},
		},
		DesiredSet: &OvnNbDesiredSet{
			Switches: []string{"sw-keep"},
			Ports:    map[string][]string{"sw-keep": {"p-keep"}},
			Acls: map[string][]OvnNbDesiredAcl{
				"sw-keep": {{Direction: "to-lport", Priority: 900, Match: "ip4.src == 10.9.0.0/24"}},
			},
		},
	}
}

// respondOwnedSwitches makes the shim answer the ownership-scoped
// `find Logical_Switch` with the given switch names (one per line).
func respondOwnedSwitches(t *testing.T, respDir string, names ...string) {
	t.Helper()
	nbAddResponse(t, respDir, "find_switches",
		"find Logical_Switch external_ids:powernode_ovn_deployment=dep-123",
		strings.Join(names, "\n")+"\n")
}

// 1) SECURITY CASE — a retracted over-permissive allow ACL must be
// deleted from the NB DB even though its parent switch survives.
func TestOvnNbPrune_RetractedAclDeletedIndependentlyOfSwitch(t *testing.T) {
	skipUnlessPosix(t)
	nbctlBin, logPath, _, respDir := newNbRespondingBin(t)
	a := &ShellOvnNbApplier{OvnNbctlBin: nbctlBin}

	respondOwnedSwitches(t, respDir, "sw-keep")
	nbAddResponse(t, respDir, "acl_list", "acl-list sw-keep",
		" to-lport  1000 (ip4.src == 0.0.0.0/0) allow\n"+
			" to-lport   900 (ip4.src == 10.9.0.0/24) allow\n")
	nbAddResponse(t, respDir, "lsp_list", "lsp-list sw-keep",
		" 6f6b0000-0000-0000-0000-000000000001 (p-keep)\n")

	obs, err := a.Apply(context.Background(), prunePlan())
	if err != nil {
		t.Fatalf("apply: %v", err)
	}
	calls := nbReadCalls(t, logPath)
	if !strings.Contains(calls, "acl-del sw-keep to-lport 1000 ip4.src == 0.0.0.0/0") {
		t.Fatalf("retracted over-permissive ACL was not pruned; calls:\n%s", calls)
	}
	if strings.Contains(calls, "acl-del sw-keep to-lport 900") {
		t.Fatalf("desired ACL must not be pruned; calls:\n%s", calls)
	}
	if strings.Contains(calls, "ls-del") {
		t.Fatalf("surviving switch must not be deleted; calls:\n%s", calls)
	}
	if obs.PruneDeleted != 1 {
		t.Fatalf("expected PruneDeleted=1, got %d", obs.PruneDeleted)
	}
}

// 2) A deactivated switch absent from the manifest is deleted (ls-del
// cascades its ports and ACLs in OVN), while manifest switches survive.
func TestOvnNbPrune_DeactivatedSwitchDeleted(t *testing.T) {
	skipUnlessPosix(t)
	nbctlBin, logPath, _, respDir := newNbRespondingBin(t)
	a := &ShellOvnNbApplier{OvnNbctlBin: nbctlBin}

	respondOwnedSwitches(t, respDir, "sw-keep", "sw-gone")
	nbAddResponse(t, respDir, "acl_list", "acl-list sw-keep",
		" to-lport   900 (ip4.src == 10.9.0.0/24) allow\n")
	nbAddResponse(t, respDir, "lsp_list", "lsp-list sw-keep",
		" 6f6b0000-0000-0000-0000-000000000001 (p-keep)\n")

	if _, err := a.Apply(context.Background(), prunePlan()); err != nil {
		t.Fatalf("apply: %v", err)
	}
	calls := nbReadCalls(t, logPath)
	if !strings.Contains(calls, "--if-exists ls-del sw-gone") {
		t.Fatalf("deactivated switch was not pruned; calls:\n%s", calls)
	}
	if strings.Contains(calls, "ls-del sw-keep") {
		t.Fatalf("manifest switch must never be deleted; calls:\n%s", calls)
	}
}

// 3) An orphan port on a surviving switch is pruned; desired port kept.
func TestOvnNbPrune_OrphanPortDeleted(t *testing.T) {
	skipUnlessPosix(t)
	nbctlBin, logPath, _, respDir := newNbRespondingBin(t)
	a := &ShellOvnNbApplier{OvnNbctlBin: nbctlBin}

	respondOwnedSwitches(t, respDir, "sw-keep")
	nbAddResponse(t, respDir, "lsp_list", "lsp-list sw-keep",
		" 6f6b0000-0000-0000-0000-000000000001 (p-keep)\n"+
			" 6f6b0000-0000-0000-0000-000000000002 (p-gone)\n")

	if _, err := a.Apply(context.Background(), prunePlan()); err != nil {
		t.Fatalf("apply: %v", err)
	}
	calls := nbReadCalls(t, logPath)
	if !strings.Contains(calls, "--if-exists lsp-del p-gone") {
		t.Fatalf("orphan port was not pruned; calls:\n%s", calls)
	}
	if strings.Contains(calls, "lsp-del p-keep") {
		t.Fatalf("desired port must not be pruned; calls:\n%s", calls)
	}
}

// 4) OWNERSHIP SCOPING — prune candidates come ONLY from the
// deployment-stamped `find`; an unowned (hand-made) switch that the
// manifest omits is untouchable even though it exists in the NB DB.
func TestOvnNbPrune_NeverTouchesUnownedRows(t *testing.T) {
	skipUnlessPosix(t)
	nbctlBin, logPath, _, respDir := newNbRespondingBin(t)
	a := &ShellOvnNbApplier{OvnNbctlBin: nbctlBin}

	// The NB DB also contains operator-made "sw-manual" — but the
	// ownership find (correctly) does not return it.
	respondOwnedSwitches(t, respDir, "sw-keep")

	if _, err := a.Apply(context.Background(), prunePlan()); err != nil {
		t.Fatalf("apply: %v", err)
	}
	calls := nbReadCalls(t, logPath)
	if !strings.Contains(calls, "find Logical_Switch external_ids:powernode_ovn_deployment=dep-123") {
		t.Fatalf("prune must scope candidates by the ownership stamp; calls:\n%s", calls)
	}
	if strings.Contains(calls, "sw-manual") {
		t.Fatalf("unowned switch must never appear in any prune command; calls:\n%s", calls)
	}
}

// 5) A missing manifest (old server payload) means NO prune — absence
// is not an instruction to delete everything.
func TestOvnNbPrune_NoManifestNoPrune(t *testing.T) {
	skipUnlessPosix(t)
	nbctlBin, logPath, _, _ := newNbRespondingBin(t)
	a := &ShellOvnNbApplier{OvnNbctlBin: nbctlBin}

	plan := prunePlan()
	plan.DesiredSet = nil
	if _, err := a.Apply(context.Background(), plan); err != nil {
		t.Fatalf("apply: %v", err)
	}
	calls := nbReadCalls(t, logPath)
	for _, verb := range []string{"find", "ls-del", "lsp-del", "acl-del"} {
		if strings.Contains(calls, verb) {
			t.Fatalf("no-manifest plan must not issue %q; calls:\n%s", verb, calls)
		}
	}
}

// 6) An EMPTY desired set (zero switches) must prune nothing — the
// empty-set guard. A compiler bug emitting an empty manifest must not
// become mass deletion of NB state.
func TestOvnNbPrune_EmptyManifestNoPrune(t *testing.T) {
	skipUnlessPosix(t)
	nbctlBin, logPath, _, respDir := newNbRespondingBin(t)
	a := &ShellOvnNbApplier{OvnNbctlBin: nbctlBin}

	// Even with owned switches present in NB...
	respondOwnedSwitches(t, respDir, "sw-keep", "sw-gone")

	plan := prunePlan()
	plan.DesiredSet = &OvnNbDesiredSet{Switches: []string{}}
	if _, err := a.Apply(context.Background(), plan); err != nil {
		t.Fatalf("apply: %v", err)
	}
	calls := nbReadCalls(t, logPath)
	for _, verb := range []string{"ls-del", "lsp-del", "acl-del"} {
		if strings.Contains(calls, verb) {
			t.Fatalf("empty manifest must not issue %q; calls:\n%s", verb, calls)
		}
	}
}

// 7) If the ownership listing itself fails, the prune measures nothing
// and deletes nothing; the failure is reported as an error.
func TestOvnNbPrune_ListFailureMeansNoDeletes(t *testing.T) {
	skipUnlessPosix(t)
	nbctlBin, logPath, failPath, _ := newNbRespondingBin(t)
	a := &ShellOvnNbApplier{OvnNbctlBin: nbctlBin}

	nbSetFailOn(t, failPath, "find Logical_Switch")

	obs, err := a.Apply(context.Background(), prunePlan())
	if err == nil {
		t.Fatalf("expected error when the ownership listing fails")
	}
	calls := nbReadCalls(t, logPath)
	for _, verb := range []string{"ls-del", "lsp-del", "acl-del"} {
		if strings.Contains(calls, verb) {
			t.Fatalf("failed listing must not issue %q; calls:\n%s", verb, calls)
		}
	}
	if obs == nil || obs.LastPruneError == "" {
		t.Fatalf("expected LastPruneError to be reported, got %+v", obs)
	}
}

// 8) A failed delete is an ERROR observation — reported, never a silent
// skip, never ok — and the replay side still converges the add half.
func TestOvnNbPrune_FailedDeleteReportedAsError(t *testing.T) {
	skipUnlessPosix(t)
	nbctlBin, logPath, failPath, respDir := newNbRespondingBin(t)
	a := &ShellOvnNbApplier{OvnNbctlBin: nbctlBin}

	respondOwnedSwitches(t, respDir, "sw-keep")
	nbAddResponse(t, respDir, "acl_list", "acl-list sw-keep",
		" to-lport  1000 (ip4.src == 0.0.0.0/0) allow\n")
	nbSetFailOn(t, failPath, "acl-del")

	obs, err := a.Apply(context.Background(), prunePlan())
	if err == nil {
		t.Fatalf("expected error for the failed acl-del")
	}
	if obs == nil {
		t.Fatalf("expected observation alongside the error")
	}
	if obs.PruneFailed != 1 {
		t.Fatalf("expected PruneFailed=1, got %d", obs.PruneFailed)
	}
	if !strings.Contains(obs.LastPruneError, "acl-del") {
		t.Fatalf("LastPruneError should name the failed delete, got %q", obs.LastPruneError)
	}
	// The replay (add side) must still have run: security adds cannot
	// be held hostage by a failed delete.
	calls := nbReadCalls(t, logPath)
	if !strings.Contains(calls, "acl-add sw-keep to-lport 900") {
		t.Fatalf("replay should still run after prune failures; calls:\n%s", calls)
	}
	// And the replay half is reported clean — the error is prune-side.
	if obs.LastError != "" {
		t.Fatalf("replay-side LastError should stay empty, got %q", obs.LastError)
	}
	if obs.AppliedCommands != obs.PlanCommands {
		t.Fatalf("expected full replay, got %d/%d", obs.AppliedCommands, obs.PlanCommands)
	}
}

// 9) Failed prunes must not seed the byte-identical-replay cache — the
// next tick has to retry rather than short-circuit.
func TestOvnNbPrune_FailureNotCached(t *testing.T) {
	skipUnlessPosix(t)
	nbctlBin, logPath, failPath, respDir := newNbRespondingBin(t)
	a := &ShellOvnNbApplier{OvnNbctlBin: nbctlBin}

	respondOwnedSwitches(t, respDir, "sw-keep")
	nbAddResponse(t, respDir, "acl_list", "acl-list sw-keep",
		" to-lport  1000 (ip4.src == 0.0.0.0/0) allow\n")
	nbSetFailOn(t, failPath, "acl-del")

	if _, err := a.Apply(context.Background(), prunePlan()); err == nil {
		t.Fatalf("expected first apply to error")
	}
	nbSetFailOn(t, failPath, "") // fault clears
	obs, err := a.Apply(context.Background(), prunePlan())
	if err != nil {
		t.Fatalf("second apply: %v", err)
	}
	if obs.CacheHit {
		t.Fatalf("second apply must not be a cache hit after a failed prune")
	}
	calls := nbReadCalls(t, logPath)
	if strings.Count(calls, "acl-del sw-keep to-lport 1000") != 2 {
		t.Fatalf("expected the delete retried on the second apply; calls:\n%s", calls)
	}
}

// 10) Delete ordering — child prunes (ACLs, ports) on surviving
// switches are issued before any ls-del of a doomed switch.
func TestOvnNbPrune_ChildDeletesBeforeSwitchDeletes(t *testing.T) {
	skipUnlessPosix(t)
	nbctlBin, logPath, _, respDir := newNbRespondingBin(t)
	a := &ShellOvnNbApplier{OvnNbctlBin: nbctlBin}

	respondOwnedSwitches(t, respDir, "sw-keep", "sw-gone")
	nbAddResponse(t, respDir, "acl_list", "acl-list sw-keep",
		" to-lport  1000 (ip4.src == 0.0.0.0/0) allow\n")
	nbAddResponse(t, respDir, "lsp_list", "lsp-list sw-keep",
		" 6f6b0000-0000-0000-0000-000000000002 (p-gone)\n")

	if _, err := a.Apply(context.Background(), prunePlan()); err != nil {
		t.Fatalf("apply: %v", err)
	}
	calls := nbReadCalls(t, logPath)
	aclDel := strings.Index(calls, "acl-del")
	lspDel := strings.Index(calls, "lsp-del")
	lsDel := strings.Index(calls, "ls-del sw-gone")
	if aclDel == -1 || lspDel == -1 || lsDel == -1 {
		t.Fatalf("expected acl-del, lsp-del and ls-del all issued; calls:\n%s", calls)
	}
	if !(aclDel < lsDel && lspDel < lsDel) {
		t.Fatalf("child deletes must precede switch deletes; calls:\n%s", calls)
	}
}

// 11) The `set` plan verb is allow-listed ONLY for the ownership stamp
// shape — anything else is rejected before a single command runs.
func TestOvnNbApply_SetCommandRestrictedToOwnershipStamp(t *testing.T) {
	skipUnlessPosix(t)
	nbctlBin, logPath, _, _ := newNbRespondingBin(t)
	a := &ShellOvnNbApplier{OvnNbctlBin: nbctlBin}

	for _, rogue := range [][]string{
		{"Logical_Switch", "sw-keep", "other_column=x"},
		{"NB_Global", ".", "external_ids:powernode_ovn_deployment=dep-123"},
		{"Logical_Switch", "sw-keep"},
		{"Logical_Switch", "sw-keep", "external_ids:powernode_ovn_deployment=dep-123", "extra"},
	} {
		plan := prunePlan()
		plan.DesiredSet = nil
		plan.Plan = []OvnNbCommand{{Cmd: "set", Args: rogue}}
		if _, err := a.Apply(context.Background(), plan); err == nil {
			t.Fatalf("rogue set %v must be rejected", rogue)
		}
	}
	if calls := nbReadCalls(t, logPath); calls != "" {
		t.Fatalf("rejected plans must not execute anything; calls:\n%s", calls)
	}
}

// 12) The steady-state cache must key on the desired set too: a manifest
// change with an identical command plan must NOT short-circuit.
func TestOvnNbPrune_CacheKeysOnDesiredSet(t *testing.T) {
	skipUnlessPosix(t)
	nbctlBin, _, _, respDir := newNbRespondingBin(t)
	a := &ShellOvnNbApplier{OvnNbctlBin: nbctlBin}

	respondOwnedSwitches(t, respDir, "sw-keep")

	if _, err := a.Apply(context.Background(), prunePlan()); err != nil {
		t.Fatalf("first apply: %v", err)
	}
	changed := prunePlan()
	changed.DesiredSet.Ports["sw-keep"] = []string{"p-keep", "p-extra"}
	obs, err := a.Apply(context.Background(), changed)
	if err != nil {
		t.Fatalf("second apply: %v", err)
	}
	if obs.CacheHit {
		t.Fatalf("manifest change must invalidate the replay cache")
	}
}

// 13) ADOPTION — on the first tick after upgrade nothing is stamped
// yet, so the prune can't see pre-fix garbage. The replay stamps the
// switches; the cache must NOT seed on that tick, so the next tick
// re-prunes against the adopted set instead of short-circuiting.
func TestOvnNbPrune_UnadoptedFirstTickNotCached(t *testing.T) {
	skipUnlessPosix(t)
	nbctlBin, logPath, _, respDir := newNbRespondingBin(t)
	a := &ShellOvnNbApplier{OvnNbctlBin: nbctlBin}

	// The ownership find returns NOTHING owned (empty stdout).
	respondOwnedSwitches(t, respDir)

	if _, err := a.Apply(context.Background(), prunePlan()); err != nil {
		t.Fatalf("first apply: %v", err)
	}
	obs, err := a.Apply(context.Background(), prunePlan())
	if err != nil {
		t.Fatalf("second apply: %v", err)
	}
	if obs.CacheHit {
		t.Fatalf("unadopted prune must not seed the replay cache")
	}
	calls := nbReadCalls(t, logPath)
	if got := strings.Count(calls, "ls-add sw-keep"); got != 2 {
		t.Fatalf("expected the replay re-executed on the second tick, ls-add count=%d; calls:\n%s", got, calls)
	}
}
