// ovn_nb_applier_test.go — unit tests for the Phase 3b-2 OVN
// Northbound plan applier.
//
// Strategy: install a fake `ovn-nbctl` binary in tempdir using the
// recorder-shim pattern from ovn_controller_applier_test. The shim
// appends each invocation's argv to a shared call log so tests can
// assert which commands ran, in what order, with which flags. A
// sentinel "fail-on" file lets a test make the shim exit non-zero for
// a chosen subcommand to exercise the partial-apply error path.
//
// No ovn-nbctl, no OVN DB, no root required.

package sdwan

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// newNbRecorderBin installs a fake `ovn-nbctl` binary in tempdir.
//
// Returns:
//   - nbctlBin — absolute path to the fake ovn-nbctl binary.
//   - logPath  — shared call log; each line is the full argv passed.
//   - failPath — a file whose contents, when non-empty, name a
//     substring; if the joined argv contains it the shim exits 1
//     (stderr echoes a canned ovn-nbctl-style message). Empty = all
//     invocations succeed.
func newNbRecorderBin(t *testing.T) (nbctlBin, logPath, failPath string) {
	t.Helper()

	dir := t.TempDir()
	nbctlBin = filepath.Join(dir, "ovn-nbctl")
	logPath = filepath.Join(dir, "calls")
	failPath = filepath.Join(dir, "failon")

	if err := os.WriteFile(logPath, []byte(""), 0o644); err != nil {
		t.Fatalf("seed log: %v", err)
	}
	if err := os.WriteFile(failPath, []byte(""), 0o644); err != nil {
		t.Fatalf("seed failon: %v", err)
	}

	// ovn-nbctl shim — record the argv, then optionally fail if the
	// failon sentinel matches a substring of the argv.
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
exit 0
`, logPath, failPath)

	if err := os.WriteFile(nbctlBin, []byte(script), 0o755); err != nil {
		t.Fatalf("write ovn-nbctl shim: %v", err)
	}
	return
}

func nbReadCalls(t *testing.T, logPath string) string {
	t.Helper()
	raw, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("read calls: %v", err)
	}
	return strings.TrimSpace(string(raw))
}

func nbSetFailOn(t *testing.T, failPath, needle string) {
	t.Helper()
	if err := os.WriteFile(failPath, []byte(needle), 0o644); err != nil {
		t.Fatalf("set failon: %v", err)
	}
}

func samplePlan() *OvnNbPlan {
	return &OvnNbPlan{
		DeploymentID: "dep-123",
		NbDbEndpoint: "tcp:10.0.0.1:6641",
		CompiledAt:   "2026-05-29T00:00:00Z",
		Plan: []OvnNbCommand{
			{Cmd: "ls-add", Args: []string{"my-switch"}},
			{Cmd: "lsp-add", Args: []string{"my-switch", "vm-001"}},
			{Cmd: "lsp-set-type", Args: []string{"vm-001", "localnet"}},
			{Cmd: "lsp-set-addresses", Args: []string{"vm-001", "02:11:22:33:44:55 10.0.0.5"}},
			{Cmd: "acl-add", Args: []string{"my-switch", "to-lport", "1000", "ip4.src == 10.0.0.0/24", "allow"}},
		},
	}
}

// ----------------------------------------------------------------------
// Apply contract tests
// ----------------------------------------------------------------------

// 1) nil plan → clean no-op, no shell calls, populated-but-empty obs.
func TestOvnNbApplier_NilPlanIsNoop(t *testing.T) {
	if runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("recorder shim assumes POSIX shell")
	}
	nbctlBin, logPath, _ := newNbRecorderBin(t)
	a := &ShellOvnNbApplier{OvnNbctlBin: nbctlBin}

	obs, err := a.Apply(context.Background(), nil)
	if err != nil {
		t.Fatalf("apply nil: %v", err)
	}
	if obs == nil {
		t.Fatalf("expected non-nil obs for nil plan")
	}
	if obs.PlanCommands != 0 || obs.AppliedCommands != 0 {
		t.Errorf("expected empty obs counts, got plan=%d applied=%d", obs.PlanCommands, obs.AppliedCommands)
	}
	if calls := nbReadCalls(t, logPath); calls != "" {
		t.Errorf("expected NO ovn-nbctl calls for nil plan, got:\n%s", calls)
	}
}

// 2) empty Plan slice → clean no-op even with a non-empty endpoint.
func TestOvnNbApplier_EmptyPlanIsNoop(t *testing.T) {
	nbctlBin, logPath, _ := newNbRecorderBin(t)
	a := &ShellOvnNbApplier{OvnNbctlBin: nbctlBin}

	plan := &OvnNbPlan{DeploymentID: "dep-1", NbDbEndpoint: "tcp:10.0.0.1:6641", Plan: nil}
	obs, err := a.Apply(context.Background(), plan)
	if err != nil {
		t.Fatalf("apply empty: %v", err)
	}
	if obs.DeploymentID != "dep-1" || obs.NbDbEndpoint != "tcp:10.0.0.1:6641" {
		t.Errorf("expected obs to echo plan metadata, got %+v", obs)
	}
	if calls := nbReadCalls(t, logPath); calls != "" {
		t.Errorf("expected NO ovn-nbctl calls for empty plan, got:\n%s", calls)
	}
}

// 3) full plan → every command replayed, in order, with --db= prefix.
func TestOvnNbApplier_ReplaysFullPlanInOrder(t *testing.T) {
	nbctlBin, logPath, _ := newNbRecorderBin(t)
	a := &ShellOvnNbApplier{OvnNbctlBin: nbctlBin}

	obs, err := a.Apply(context.Background(), samplePlan())
	if err != nil {
		t.Fatalf("apply: %v", err)
	}
	if obs.PlanCommands != 5 || obs.AppliedCommands != 5 {
		t.Errorf("expected 5/5 commands, got plan=%d applied=%d", obs.PlanCommands, obs.AppliedCommands)
	}
	if obs.LastError != "" {
		t.Errorf("expected no LastError, got %q", obs.LastError)
	}

	calls := nbReadCalls(t, logPath)
	lines := strings.Split(calls, "\n")
	if len(lines) != 5 {
		t.Fatalf("expected 5 invocations, got %d:\n%s", len(lines), calls)
	}

	// Every invocation must carry the --db= endpoint.
	for _, l := range lines {
		if !strings.Contains(l, "--db=tcp:10.0.0.1:6641") {
			t.Errorf("expected --db= prefix on every call, missing in: %q", l)
		}
	}

	// Order check: ls-add precedes lsp-add precedes acl-add.
	lsIdx := strings.Index(calls, " ls-add ")
	lspIdx := strings.Index(calls, " lsp-add ")
	aclIdx := strings.Index(calls, " acl-add ")
	if !(lsIdx >= 0 && lspIdx > lsIdx && aclIdx > lspIdx) {
		t.Errorf("expected ls-add < lsp-add < acl-add order; got ls@%d lsp@%d acl@%d:\n%s",
			lsIdx, lspIdx, aclIdx, calls)
	}
}

// 4) --may-exist gating — ls-add/lsp-add/acl-add get the flag; the
// lsp-set-* setters do NOT.
func TestOvnNbApplier_MayExistGating(t *testing.T) {
	nbctlBin, logPath, _ := newNbRecorderBin(t)
	a := &ShellOvnNbApplier{OvnNbctlBin: nbctlBin}

	if _, err := a.Apply(context.Background(), samplePlan()); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := nbReadCalls(t, logPath)
	lines := strings.Split(calls, "\n")
	for _, l := range lines {
		switch {
		case strings.Contains(l, " ls-add "), strings.Contains(l, " lsp-add "), strings.Contains(l, " acl-add "):
			if !strings.Contains(l, "--may-exist") {
				t.Errorf("expected --may-exist on idempotent add, missing in: %q", l)
			}
		case strings.Contains(l, " lsp-set-type "), strings.Contains(l, " lsp-set-addresses "):
			if strings.Contains(l, "--may-exist") {
				t.Errorf("expected NO --may-exist on setter, present in: %q", l)
			}
		}
	}
}

// 5) addresses string with a space survives as ONE argv element. The
// shim logs `$*` (space-joined), so we assert the full addresses value
// appears intact on the lsp-set-addresses line.
func TestOvnNbApplier_AddressesStringStaysOneArg(t *testing.T) {
	nbctlBin, logPath, _ := newNbRecorderBin(t)
	a := &ShellOvnNbApplier{OvnNbctlBin: nbctlBin}

	if _, err := a.Apply(context.Background(), samplePlan()); err != nil {
		t.Fatalf("apply: %v", err)
	}

	calls := nbReadCalls(t, logPath)
	// The set-addresses line must contain the full mac+ip string. Because
	// we pass it as a single argv element, exec doesn't word-split it; the
	// shim's `$*` re-joins argv with spaces so the substring is present.
	if !strings.Contains(calls, "lsp-set-addresses vm-001 02:11:22:33:44:55 10.0.0.5") {
		t.Errorf("expected addresses string intact, got:\n%s", calls)
	}
}

// 6) missing NbDbEndpoint with a non-empty plan → validation error,
// NO shell calls.
func TestOvnNbApplier_MissingEndpointErrors(t *testing.T) {
	nbctlBin, logPath, _ := newNbRecorderBin(t)
	a := &ShellOvnNbApplier{OvnNbctlBin: nbctlBin}

	plan := samplePlan()
	plan.NbDbEndpoint = "   "
	_, err := a.Apply(context.Background(), plan)
	if err == nil {
		t.Fatalf("expected error for empty endpoint, got nil")
	}
	if !strings.Contains(err.Error(), "NbDbEndpoint") {
		t.Errorf("expected error to mention NbDbEndpoint, got: %v", err)
	}
	if calls := nbReadCalls(t, logPath); calls != "" {
		t.Errorf("validation must short-circuit before shell-out, got:\n%s", calls)
	}
}

// 7) disallowed subcommand → error BEFORE any command is issued (the
// allow-list validation runs over the whole plan first).
func TestOvnNbApplier_DisallowedCmdErrorsBeforeAnyExec(t *testing.T) {
	nbctlBin, logPath, _ := newNbRecorderBin(t)
	a := &ShellOvnNbApplier{OvnNbctlBin: nbctlBin}

	plan := &OvnNbPlan{
		DeploymentID: "dep-1",
		NbDbEndpoint: "tcp:10.0.0.1:6641",
		Plan: []OvnNbCommand{
			{Cmd: "ls-add", Args: []string{"sw"}},
			// An off-list subcommand the compiler would never emit, but
			// which a tampered payload might.
			{Cmd: "ls-del", Args: []string{"sw"}},
		},
	}
	_, err := a.Apply(context.Background(), plan)
	if err == nil {
		t.Fatalf("expected error for disallowed cmd, got nil")
	}
	if !strings.Contains(err.Error(), "allow-list") {
		t.Errorf("expected allow-list error, got: %v", err)
	}
	// Validation runs over the whole plan first, so NOT EVEN the valid
	// ls-add should have executed.
	if calls := nbReadCalls(t, logPath); calls != "" {
		t.Errorf("expected NO exec before allow-list validation, got:\n%s", calls)
	}
}

// 8) empty Cmd → validation error before exec.
func TestOvnNbApplier_EmptyCmdErrors(t *testing.T) {
	nbctlBin, logPath, _ := newNbRecorderBin(t)
	a := &ShellOvnNbApplier{OvnNbctlBin: nbctlBin}

	plan := &OvnNbPlan{
		DeploymentID: "dep-1",
		NbDbEndpoint: "tcp:10.0.0.1:6641",
		Plan:         []OvnNbCommand{{Cmd: "  ", Args: nil}},
	}
	_, err := a.Apply(context.Background(), plan)
	if err == nil {
		t.Fatalf("expected error for empty cmd, got nil")
	}
	if calls := nbReadCalls(t, logPath); calls != "" {
		t.Errorf("expected NO exec for empty cmd, got:\n%s", calls)
	}
}

// 9) partial-apply error path — a mid-plan failure returns an error,
// reports AppliedCommands = count-before-failure, and sets LastError.
func TestOvnNbApplier_PartialApplyReportsProgress(t *testing.T) {
	nbctlBin, logPath, failPath := newNbRecorderBin(t)
	a := &ShellOvnNbApplier{OvnNbctlBin: nbctlBin}

	// Make the third command (lsp-set-type vm-001 localnet) fail.
	nbSetFailOn(t, failPath, "lsp-set-type")

	obs, err := a.Apply(context.Background(), samplePlan())
	if err == nil {
		t.Fatalf("expected error on mid-plan failure, got nil")
	}
	if obs == nil {
		t.Fatalf("expected partial-progress obs even on error")
	}
	// ls-add + lsp-add succeeded before lsp-set-type failed → 2 applied.
	if obs.AppliedCommands != 2 {
		t.Errorf("expected 2 applied before failure, got %d", obs.AppliedCommands)
	}
	if obs.PlanCommands != 5 {
		t.Errorf("expected PlanCommands=5, got %d", obs.PlanCommands)
	}
	if !strings.Contains(obs.LastError, "lsp-set-type") {
		t.Errorf("expected LastError to name the failing cmd, got %q", obs.LastError)
	}

	// The log should show ls-add, lsp-add, and the failing lsp-set-type,
	// but NOT lsp-set-addresses or acl-add (replay aborts on first error).
	calls := nbReadCalls(t, logPath)
	if strings.Contains(calls, "lsp-set-addresses") || strings.Contains(calls, "acl-add") {
		t.Errorf("expected replay to abort after failure; got later commands:\n%s", calls)
	}
}

// 10) missing ovn-nbctl binary → clear error mentioning ovn-nbctl, no
// half-applied state.
func TestOvnNbApplier_MissingBinaryErrors(t *testing.T) {
	a := &ShellOvnNbApplier{OvnNbctlBin: "/nonexistent/path/to/ovn-nbctl"}

	_, err := a.Apply(context.Background(), samplePlan())
	if err == nil {
		t.Fatalf("expected error for missing binary, got nil")
	}
	if !strings.Contains(err.Error(), "ovn-nbctl") {
		t.Errorf("expected error to mention ovn-nbctl, got: %v", err)
	}
}

// 11) idempotent steady-state short-circuit — a byte-identical second
// apply against the same endpoint issues NO further ovn-nbctl calls
// (the cache hits) yet still reports fully applied.
func TestOvnNbApplier_SteadyStateShortCircuit(t *testing.T) {
	nbctlBin, logPath, _ := newNbRecorderBin(t)
	a := &ShellOvnNbApplier{OvnNbctlBin: nbctlBin}

	if _, err := a.Apply(context.Background(), samplePlan()); err != nil {
		t.Fatalf("first apply: %v", err)
	}
	first := nbReadCalls(t, logPath)
	firstLines := len(strings.Split(first, "\n"))
	if firstLines != 5 {
		t.Fatalf("expected 5 calls on first apply, got %d:\n%s", firstLines, first)
	}

	// Second apply with the SAME plan — cache should short-circuit.
	obs, err := a.Apply(context.Background(), samplePlan())
	if err != nil {
		t.Fatalf("second apply: %v", err)
	}
	if obs.AppliedCommands != 5 {
		t.Errorf("expected 5 applied (cache reports full), got %d", obs.AppliedCommands)
	}

	second := nbReadCalls(t, logPath)
	if len(strings.Split(second, "\n")) != firstLines {
		t.Errorf("expected NO new ovn-nbctl calls on identical reapply, log grew:\n%s", second)
	}
}

// 12) changed plan invalidates the cache — a different command set after
// a successful apply must re-issue ovn-nbctl calls.
func TestOvnNbApplier_ChangedPlanReapplies(t *testing.T) {
	nbctlBin, logPath, _ := newNbRecorderBin(t)
	a := &ShellOvnNbApplier{OvnNbctlBin: nbctlBin}

	if _, err := a.Apply(context.Background(), samplePlan()); err != nil {
		t.Fatalf("first apply: %v", err)
	}
	firstLines := len(strings.Split(nbReadCalls(t, logPath), "\n"))

	// A plan with an extra switch — different signature.
	plan2 := samplePlan()
	plan2.Plan = append(plan2.Plan, OvnNbCommand{Cmd: "ls-add", Args: []string{"another-switch"}})

	if _, err := a.Apply(context.Background(), plan2); err != nil {
		t.Fatalf("second apply: %v", err)
	}
	secondLines := len(strings.Split(nbReadCalls(t, logPath), "\n"))
	if secondLines <= firstLines {
		t.Errorf("expected changed plan to re-issue calls; first=%d second=%d", firstLines, secondLines)
	}
}

// 13) Every invocation carries ovn-nbctl's own --timeout — the replay
// runs synchronously in the heartbeat loop, so an unresponsive NB
// endpoint must fail the command instead of wedging the tick.
func TestOvnNbApplier_EveryCallCarriesTimeout(t *testing.T) {
	nbctlBin, logPath, _ := newNbRecorderBin(t)
	a := &ShellOvnNbApplier{OvnNbctlBin: nbctlBin}

	if _, err := a.Apply(context.Background(), samplePlan()); err != nil {
		t.Fatalf("apply: %v", err)
	}

	for _, l := range strings.Split(nbReadCalls(t, logPath), "\n") {
		if !strings.Contains(l, "--timeout=") {
			t.Errorf("expected --timeout on every call, missing in: %q", l)
		}
	}
}

// 14) A client that ignores --timeout (here: a shim that just sleeps) is
// killed by the context deadline — a blackholed NB endpoint must not
// hold the heartbeat loop for the kernel's TCP timeout.
func TestOvnNbApplier_ContextDeadlineKillsAHungNbctl(t *testing.T) {
	dir := t.TempDir()
	bin := filepath.Join(dir, "ovn-nbctl")
	if err := os.WriteFile(bin, []byte("#!/usr/bin/env bash\nsleep 30\n"), 0o755); err != nil {
		t.Fatalf("write hung shim: %v", err)
	}
	a := &ShellOvnNbApplier{OvnNbctlBin: bin, CommandTimeout: 1 * time.Second}

	start := time.Now()
	_, err := a.Apply(context.Background(), &OvnNbPlan{
		DeploymentID: "dep-1",
		NbDbEndpoint: "tcp:10.0.0.1:6641",
		Plan:         []OvnNbCommand{{Cmd: "ls-add", Args: []string{"sw"}}},
	})
	elapsed := time.Since(start)
	if err == nil {
		t.Fatalf("expected error from hung ovn-nbctl")
	}
	// 1s --timeout + 2s kill grace; anything near the shim's 30s sleep
	// means the deadline never fired.
	if elapsed > 10*time.Second {
		t.Fatalf("hung ovn-nbctl was not killed by the deadline; took %v", elapsed)
	}
}

// 15) NoopOvnNbApplier captures plans and reports full apply without
// shelling out — the safe default on a non-Linux dev box.
func TestNoopOvnNbApplier_CapturesAndReportsApplied(t *testing.T) {
	n := &NoopOvnNbApplier{}
	obs, err := n.Apply(context.Background(), samplePlan())
	if err != nil {
		t.Fatalf("noop apply: %v", err)
	}
	if len(n.Plans) != 1 {
		t.Errorf("expected 1 captured plan, got %d", len(n.Plans))
	}
	if obs.PlanCommands != 5 || obs.AppliedCommands != 5 {
		t.Errorf("expected 5/5 from noop, got plan=%d applied=%d", obs.PlanCommands, obs.AppliedCommands)
	}

	// nil plan through noop is still safe.
	obs2, err := n.Apply(context.Background(), nil)
	if err != nil {
		t.Fatalf("noop nil apply: %v", err)
	}
	if obs2.PlanCommands != 0 {
		t.Errorf("expected 0 commands for nil plan, got %d", obs2.PlanCommands)
	}
}
