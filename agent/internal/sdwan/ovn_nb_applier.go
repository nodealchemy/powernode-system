// ovn_nb_applier.go — Phase 3b-2: agent-side applier that replays a
// platform-compiled OVN Northbound (NB) plan against the central OVN
// NB DB via `ovn-nbctl`.
//
// Where this fits relative to ovn_controller_applier.go:
//   - ovn_controller_applier.go runs on EVERY heavyweight host. It
//     manages the *local* `ovn-controller` daemon + the OVS-side encap
//     config (ovn-encap-ip / ovn-remote / system-id). That makes the
//     host a chassis that ovn-controller programs flows into.
//   - THIS file runs only on the host the platform designates as the
//     OVN deployment's control host (the one co-resident with the
//     OVN northd + NB/SB DBs). It populates the *logical* network
//     topology — logical switches, switch ports, and ACLs — in the
//     central NB DB. ovn-northd then translates that NB intent into
//     SB flows that every chassis's ovn-controller realizes.
//
// The platform's Sdwan::OvnCompiler (server side) compiles the NB model
// rows into a structured `cmd + args` plan:
//
//	{
//	  "deployment_id": "<uuid>",
//	  "nb_db_endpoint": "tcp:10.0.0.1:6641",   // added by the node_api side
//	  "plan": [
//	    { "cmd": "ls-add",            "args": ["my-switch"] },
//	    { "cmd": "lsp-add",           "args": ["my-switch", "vm-001"] },
//	    { "cmd": "lsp-set-type",      "args": ["vm-001", "localnet"] },
//	    { "cmd": "lsp-set-addresses", "args": ["vm-001", "02:.. 10.0.0.5"] },
//	    { "cmd": "acl-add",           "args": ["my-switch", "to-lport", "1000", "ip4.src == 10.0.0.0/24", "allow"] }
//	  ],
//	  "compiled_at": "2026-05-..."
//	}
//
// This applier replays each entry as `ovn-nbctl --db=<endpoint> [--may-exist]
// <cmd> <args...>`. Mirrors the shell-applier pattern established by
// ovn_controller_applier.go and nftables_applier.go: a desired-state
// struct, a small interface, a shell-exec production impl with an
// overridable binary path for tests, a no-op default for non-Linux dev
// boxes, and a status report struct fed back via the heartbeat.
//
// Idempotency contract:
//   - `ls-add` and `lsp-add` are issued with `--may-exist` so replaying
//     an unchanged plan is a clean no-op (ovn-nbctl returns success
//     rather than "already exists" error).
//   - `lsp-set-type`, `lsp-set-addresses` are setters — replaying with
//     the same value is a no-op at the NB DB layer.
//   - `acl-add` is issued with `--may-exist` so a re-applied identical
//     ACL row is a no-op. (ovn-nbctl supports `--may-exist` on acl-add
//     and matches on direction+priority+match.)
//
// The applier does NOT delete NB rows the plan omits. The platform's
// OvnCompiler emits only `active` rows, so a removed switch/port simply
// disappears from the plan. Reconciling removals (NB rows present on
// the chassis but absent from the plan) is intentionally out of scope
// for 3b-2 — the compiler is additive-only in this phase, matching the
// "compiler is intentionally minimal in O3" note in ovn_compiler.rb.
// A future slice can add a prune pass once the compiler emits a
// desired-set manifest the applier can diff against.

package sdwan

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"sync"
	"time"
)

// nowRFC3339 is the package-local timestamp helper for status reports.
// Mirrors the inline `time.Now().UTC().Format(time.RFC3339)` idiom used
// in manager.go; pulled into a one-liner so the NB applier's several
// report sites stay readable.
func nowRFC3339() string {
	return time.Now().UTC().Format(time.RFC3339)
}

// OvnNbPlan is the per-host compiled Northbound plan delivered via
// node_api. Nil for lightweight hosts and accounts with no active
// Sdwan::OvnDeployment; served to every heavyweight host whose account
// has an active deployment (the `--may-exist` replay is idempotent, so
// concurrent serves converge). Mirrors Sdwan::OvnCompiler#compile output
// plus the NbDbEndpoint the node_api SDWAN-config side stamps in (the
// compiler itself doesn't know the endpoint — that lives on the
// Sdwan::OvnDeployment row).
type OvnNbPlan struct {
	// DeploymentID is the Sdwan::OvnDeployment UUID this plan compiles.
	// Carried for log/heartbeat correlation; the applier does not use
	// it to address ovn-nbctl.
	DeploymentID string `json:"deployment_id"`
	// NbDbEndpoint is the ovn-nbctl connection string for the central
	// NB DB, e.g. "tcp:10.0.0.1:6641" or "unix:/var/run/ovn/ovnnb_db.sock".
	// Required when Plan is non-empty; an empty value with a non-empty
	// plan yields a validation error from Apply (we refuse to guess the
	// local default socket because the control host's NB DB may be
	// remote-over-SDWAN).
	NbDbEndpoint string `json:"nb_db_endpoint"`
	// Plan is the ordered list of ovn-nbctl command entries. Replayed
	// top-to-bottom; the compiler emits in dependency-respecting order
	// (switches, then ports, then ACLs).
	Plan []OvnNbCommand `json:"plan"`
	// CompiledAt is the RFC3339 timestamp the platform compiled the plan.
	// Carried through to the status report for operator correlation.
	CompiledAt string `json:"compiled_at"`
}

// OvnNbCommand is one `cmd + args` entry from the compiled plan. The
// compiler leaves quoting to the consumer — args carry the unquoted
// parts, and we hand each arg to exec.Command as a distinct argv
// element (no shell, so no re-quoting needed).
type OvnNbCommand struct {
	Cmd  string   `json:"cmd"`
	Args []string `json:"args"`
}

// ObservedOvnNbState is what the NB applier reports back via the
// heartbeat after replaying a plan. The platform can surface
// AppliedCommands / FailedCommands on the OVN deployment detail page
// and alert when LastError is set.
type ObservedOvnNbState struct {
	DeploymentID    string `json:"deployment_id"`
	NbDbEndpoint    string `json:"nb_db_endpoint"`
	PlanCommands    int    `json:"plan_commands"`
	AppliedCommands int    `json:"applied_commands"`
	CompiledAt      string `json:"compiled_at"`
	LastReplayAt    string `json:"last_replay_at"`
	LastError       string `json:"last_error,omitempty"`
}

// nbAllowedCmds is the allow-list of ovn-nbctl subcommands the applier
// will replay. The plan comes from a trusted platform compiler, but we
// gate the subcommand anyway so a future compiler bug (or a tampered
// payload on a compromised control channel) can't turn the applier into
// an arbitrary-ovn-nbctl-exec primitive. Anything off-list returns an
// error and aborts the replay before issuing the offending command.
var nbAllowedCmds = map[string]struct{}{
	"ls-add":            {},
	"lsp-add":           {},
	"lsp-set-type":      {},
	"lsp-set-addresses": {},
	"lsp-set-options":   {},
	"acl-add":           {},
}

// nbMayExistCmds is the subset of allowed subcommands that accept the
// `--may-exist` flag. Issuing it makes re-adding an existing row a
// no-op instead of an error, which is what gives the replay its
// idempotency. Setters (lsp-set-*) are inherently idempotent and don't
// take the flag.
var nbMayExistCmds = map[string]struct{}{
	"ls-add":  {},
	"lsp-add": {},
	"acl-add": {},
}

// OvnNbApplier is the strategy-pattern interface for replaying a
// compiled NB plan. ShellOvnNbApplier is the production implementation;
// tests inject NoopOvnNbApplier (or a ShellOvnNbApplier pointed at a
// fake ovn-nbctl binary).
type OvnNbApplier interface {
	// Apply replays plan against its NbDbEndpoint and returns the
	// observed state. A nil plan (or a plan with no commands) is a clean
	// no-op that still returns a populated ObservedOvnNbState so the
	// caller can report "nothing to do" rather than omit the block.
	Apply(ctx context.Context, plan *OvnNbPlan) (*ObservedOvnNbState, error)
}

// ShellOvnNbApplier shells out to `ovn-nbctl`. The binary path is
// overridable for tests (the recorder-shim pattern from
// ovn_controller_applier_test). Holds a small mutex-guarded cache of
// the last-applied plan so a steady-state tick can short-circuit a
// byte-identical replay — the underlying ovn-nbctl commands are
// idempotent so the cache is an optimization, not a correctness
// requirement (matching ShellOvnControllerApplier's caching note).
type ShellOvnNbApplier struct {
	// OvnNbctlBin overrides the `ovn-nbctl` binary path. Empty falls
	// back to "ovn-nbctl" looked up via $PATH.
	OvnNbctlBin string

	mu            sync.Mutex
	lastEndpoint  string
	lastSignature string
}

// NewShellOvnNbApplier returns a default-configured applier that shells
// out to the system `ovn-nbctl`.
func NewShellOvnNbApplier() *ShellOvnNbApplier {
	return &ShellOvnNbApplier{}
}

func (a *ShellOvnNbApplier) ovnNbctl() string {
	if a.OvnNbctlBin != "" {
		return a.OvnNbctlBin
	}
	return "ovn-nbctl"
}

// Apply replays the plan. See OvnNbApplier.Apply for the contract.
func (a *ShellOvnNbApplier) Apply(ctx context.Context, plan *OvnNbPlan) (*ObservedOvnNbState, error) {
	// nil plan or empty command list — this host is not the OVN control
	// host (or the deployment has no logical topology yet). Clean no-op.
	if plan == nil || len(plan.Plan) == 0 {
		obs := &ObservedOvnNbState{}
		if plan != nil {
			obs.DeploymentID = plan.DeploymentID
			obs.NbDbEndpoint = plan.NbDbEndpoint
			obs.CompiledAt = plan.CompiledAt
		}
		a.mu.Lock()
		a.lastEndpoint = ""
		a.lastSignature = ""
		a.mu.Unlock()
		return obs, nil
	}

	if strings.TrimSpace(plan.NbDbEndpoint) == "" {
		return nil, errors.New("ovn nb apply: NbDbEndpoint is required when plan is non-empty (got empty)")
	}

	// Validate every command's subcommand against the allow-list BEFORE
	// issuing any of them, so a single bad entry can't leave the NB DB
	// half-applied. Empty Cmd is rejected too.
	for i, c := range plan.Plan {
		cmd := strings.TrimSpace(c.Cmd)
		if cmd == "" {
			return nil, fmt.Errorf("ovn nb apply: plan[%d] has empty cmd", i)
		}
		if _, ok := nbAllowedCmds[cmd]; !ok {
			return nil, fmt.Errorf("ovn nb apply: plan[%d] cmd %q is not in the ovn-nbctl allow-list", i, cmd)
		}
	}

	// Pre-flight: the production replay needs ovn-nbctl. Surface a clear
	// error rather than the cryptic "exec: not found" from the first
	// shell-out. Mirrors ovn_controller_applier.go's LookPath pre-flight.
	if a.OvnNbctlBin == "" {
		if _, err := exec.LookPath("ovn-nbctl"); err != nil {
			return nil, fmt.Errorf("ovn-nbctl not found in PATH: %w (the OVN control host requires the OVN NB client)", err)
		}
	} else {
		if _, err := exec.LookPath(a.OvnNbctlBin); err != nil {
			return nil, fmt.Errorf("ovn-nbctl override %q not executable: %w", a.OvnNbctlBin, err)
		}
	}

	// Short-circuit a byte-identical replay against the same endpoint.
	sig := planSignature(plan)
	a.mu.Lock()
	cached := a.lastSignature != "" && a.lastSignature == sig && a.lastEndpoint == plan.NbDbEndpoint
	a.mu.Unlock()
	if cached {
		return &ObservedOvnNbState{
			DeploymentID:    plan.DeploymentID,
			NbDbEndpoint:    plan.NbDbEndpoint,
			PlanCommands:    len(plan.Plan),
			AppliedCommands: len(plan.Plan),
			CompiledAt:      plan.CompiledAt,
			LastReplayAt:    nowRFC3339(),
		}, nil
	}

	applied := 0
	for i, c := range plan.Plan {
		if err := a.replayOne(ctx, plan.NbDbEndpoint, c); err != nil {
			// Report partial progress so the operator can see how far the
			// replay got before the failing command. We do NOT cache on
			// failure — the next tick re-attempts the full plan from the
			// top (every command is idempotent, so re-running the ones
			// that already succeeded is safe).
			obs := &ObservedOvnNbState{
				DeploymentID:    plan.DeploymentID,
				NbDbEndpoint:    plan.NbDbEndpoint,
				PlanCommands:    len(plan.Plan),
				AppliedCommands: applied,
				CompiledAt:      plan.CompiledAt,
				LastReplayAt:    nowRFC3339(),
				LastError:       fmt.Sprintf("plan[%d] %s: %v", i, c.Cmd, err),
			}
			return obs, fmt.Errorf("ovn nb apply: plan[%d] %s %v: %w", i, c.Cmd, c.Args, err)
		}
		applied++
	}

	a.mu.Lock()
	a.lastEndpoint = plan.NbDbEndpoint
	a.lastSignature = sig
	a.mu.Unlock()

	return &ObservedOvnNbState{
		DeploymentID:    plan.DeploymentID,
		NbDbEndpoint:    plan.NbDbEndpoint,
		PlanCommands:    len(plan.Plan),
		AppliedCommands: applied,
		CompiledAt:      plan.CompiledAt,
		LastReplayAt:    nowRFC3339(),
	}, nil
}

// replayOne issues a single `ovn-nbctl --db=<endpoint> [--may-exist]
// <cmd> <args...>`. The subcommand is already allow-list-validated by
// the caller. Each arg is passed as a distinct argv element — no shell
// interpolation — so values containing spaces (e.g. an addresses string
// "02:.. 10.0.0.5") survive intact as one ovn-nbctl argument.
func (a *ShellOvnNbApplier) replayOne(ctx context.Context, endpoint string, c OvnNbCommand) error {
	cmd := strings.TrimSpace(c.Cmd)

	argv := make([]string, 0, len(c.Args)+3)
	argv = append(argv, "--db="+endpoint)
	if _, ok := nbMayExistCmds[cmd]; ok {
		argv = append(argv, "--may-exist")
	}
	argv = append(argv, cmd)
	argv = append(argv, c.Args...)

	command := exec.CommandContext(ctx, a.ovnNbctl(), argv...)
	var stdout, stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	if err := command.Run(); err != nil {
		return fmt.Errorf("%w; stderr=%s", err, strings.TrimSpace(stderr.String()))
	}
	return nil
}

// planSignature builds a stable string fingerprint of the plan's
// command sequence for the steady-state short-circuit cache. The
// platform compiler already emits a byte-stable plan for unchanged NB
// state (ordered by name), so a simple join is sufficient — no hashing
// needed for correctness, and a collision only costs one redundant
// (idempotent) replay.
func planSignature(plan *OvnNbPlan) string {
	var b strings.Builder
	for _, c := range plan.Plan {
		b.WriteString(c.Cmd)
		b.WriteByte('\x1f') // unit separator — can't appear in a subcommand
		for _, a := range c.Args {
			b.WriteString(a)
			b.WriteByte('\x1e') // record separator
		}
		b.WriteByte('\n')
	}
	return b.String()
}

// NoopOvnNbApplier is the test-side / non-Linux-dev-box applier. It
// captures the plans it was handed without shelling out, and returns a
// fully-applied ObservedOvnNbState so callers exercise the happy path.
// Lives in production code so the Manager has a safe default on a box
// without ovn-nbctl installed (mirrors NoopNftablesApplier).
type NoopOvnNbApplier struct {
	Plans []*OvnNbPlan
}

func (n *NoopOvnNbApplier) Apply(_ context.Context, plan *OvnNbPlan) (*ObservedOvnNbState, error) {
	n.Plans = append(n.Plans, plan)
	obs := &ObservedOvnNbState{}
	if plan != nil {
		obs.DeploymentID = plan.DeploymentID
		obs.NbDbEndpoint = plan.NbDbEndpoint
		obs.PlanCommands = len(plan.Plan)
		obs.AppliedCommands = len(plan.Plan)
		obs.CompiledAt = plan.CompiledAt
		obs.LastReplayAt = nowRFC3339()
	}
	return obs, nil
}

// ----------------------------------------------------------------------
// Compile-time assertions
// ----------------------------------------------------------------------

var (
	_ OvnNbApplier = (*ShellOvnNbApplier)(nil)
	_ OvnNbApplier = (*NoopOvnNbApplier)(nil)
)
