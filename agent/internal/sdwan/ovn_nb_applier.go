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
// Removal convergence (IMP-178a7e79fa0d): alongside the plan the
// compiler ships a `desired_set` manifest declaring every switch, port,
// and ACL that SHOULD exist. Before replaying the (additive) plan the
// applier prunes NB rows the manifest omits, mirroring the wg/nft/NAT
// orphan reapers in manager.go and the nat applier's flush-then-apply.
// Safety rails, in order of importance:
//   - OWNERSHIP: prune candidates come ONLY from
//     `find Logical_Switch external_ids:powernode_ovn_deployment=<id>`
//     — the stamp the compiler's create path sets on every emitted
//     switch. Rows the platform never stamped are untouchable, as are
//     other deployments' rows. Ports/ACLs are pruned only on owned
//     switches (children of an owned switch are platform-managed).
//   - NOT-MEASURED vs MEASURED-ZERO: a missing manifest (old server
//     payload, failed compile) or an EMPTY one (zero switches) prunes
//     NOTHING. Absence of a manifest is not an instruction to delete
//     everything. Consequence: retracting the LAST switch of a
//     deployment does not prune it — the guard deliberately keeps that
//     residual rather than let a compiler bug empty the NB DB.
//   - ORDER: child deletes (acl-del, then lsp-del) are issued on
//     surviving switches before any `ls-del`; a doomed switch is
//     deleted with a single `ls-del`, which cascades its own ports and
//     ACLs atomically inside OVN (no dependency-failure window).
//   - HONESTY: every failed delete is collected and reported
//     (PruneFailed / LastPruneError) and Apply returns an error — never
//     a silent skip, never `ok`. Failed prunes also block the replay
//     cache so the next tick retries.
// Prune runs BEFORE the replay so any false-positive delete of a
// still-desired row (e.g. an ACL whose match text OVN re-canonicalized)
// is re-added by the very same tick's replay.

package sdwan

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os/exec"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

// nbSafeNameRe matches the platform's NAME_FORMAT for switches/ports
// (letters, digits, _, -, .) — also the shape of a UUID, so it doubles
// as the deployment-id check in the ownership stamp.
var nbSafeNameRe = regexp.MustCompile(`^[\w\-.]+$`)

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
	// DesiredSet is the prune manifest (IMP-178a7e79fa0d): the full set
	// of switches/ports/ACLs that should exist for this deployment. Nil
	// on payloads from servers that predate it — which disables the
	// prune pass entirely (NOT MEASURED, never "delete everything").
	DesiredSet *OvnNbDesiredSet `json:"desired_set,omitempty"`
}

// OvnNbDesiredSet mirrors Sdwan::OvnCompiler#build_desired_set. Ports
// and Acls are keyed by switch name. An empty Switches slice is a
// measured zero at compile time but is still treated as a no-prune
// guard here: a wrong empty manifest must never become mass deletion
// of NB state (the trade-off is documented in the file header).
type OvnNbDesiredSet struct {
	Switches []string                     `json:"switches"`
	Ports    map[string][]string          `json:"ports"`
	Acls     map[string][]OvnNbDesiredAcl `json:"acls"`
}

// OvnNbDesiredAcl identifies one desired ACL by the same triple
// `ovn-nbctl acl-del` addresses rows with. The platform's active-ACL
// uniqueness guard on (switch, direction, priority) makes the pair a
// stable identity; Match disambiguates an in-place edit (same slot,
// new expression) so the stale expression is pruned and the replay
// re-adds the desired one.
type OvnNbDesiredAcl struct {
	Direction string `json:"direction"`
	Priority  int    `json:"priority"`
	Match     string `json:"match"`
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
	// CacheHit marks an observation produced by the byte-identical-replay
	// short-circuit, which EXECUTED NOTHING this tick — its counts and
	// LastReplayAt re-assert the last real replay rather than a fresh one
	// (IMP-57e9a90598ee). The cache is only ever seeded by a completed
	// successful replay and never by a failure, so a full-success
	// observation with CacheHit still implies a real replay happened
	// against this endpoint+plan earlier in this process — but a consumer
	// must not read its timestamp as evidence the NB DB is reachable NOW.
	CacheHit bool `json:"cache_hit,omitempty"`
	// PruneDeleted / PruneFailed / LastPruneError report the removal
	// half (IMP-178a7e79fa0d). They are deliberately SEPARATE from
	// LastError: LastError keeps meaning "the additive replay failed",
	// which the platform's DeploymentReconciler reads as the NB DB not
	// being positively observed. A failed delete with a clean replay is
	// still a positive NB observation — the topology is applied — so it
	// must not flip the deployment's activation verdict; it is surfaced
	// here (and via Apply's error return) instead of being folded into
	// LastError.
	PruneDeleted   int    `json:"prune_deleted,omitempty"`
	PruneFailed    int    `json:"prune_failed,omitempty"`
	LastPruneError string `json:"last_prune_error,omitempty"`
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
	// "set" is allowed ONLY in the ownership-stamp shape — see
	// validateNbSetCommand. A generic `set` would be an
	// arbitrary-NB-write primitive, which the allow-list exists to
	// prevent.
	"set": {},
}

// nbOwnershipStampKey is the external_ids key the compiler stamps on
// every emitted switch and the prune pass scopes its candidates by.
// Must match Sdwan::OvnCompiler's stamp emission verbatim.
const nbOwnershipStampKey = "external_ids:powernode_ovn_deployment"

// validateNbSetCommand restricts the `set` plan verb to exactly the
// compiler's ownership stamp:
//
//	set Logical_Switch <switch> external_ids:powernode_ovn_deployment=<id>
//
// Anything else — another table, another column, extra args — is
// rejected so a compiler bug or tampered payload can't use `set` to
// rewrite arbitrary NB state (or to claim ownership via a key we would
// then prune by... note the stamp itself IS the ownership claim, so the
// shape check pins table+column; the switch name is constrained to the
// same character set the platform's models enforce).
func validateNbSetCommand(args []string) error {
	if len(args) != 3 {
		return fmt.Errorf("set expects exactly 3 args (table, row, ownership stamp), got %d", len(args))
	}
	if args[0] != "Logical_Switch" {
		return fmt.Errorf("set is only allowed on Logical_Switch, got table %q", args[0])
	}
	if !nbSafeNameRe.MatchString(args[1]) {
		return fmt.Errorf("set row name %q is not a valid switch name", args[1])
	}
	kv := strings.SplitN(args[2], "=", 2)
	if len(kv) != 2 || kv[0] != nbOwnershipStampKey || !nbSafeNameRe.MatchString(kv[1]) {
		return fmt.Errorf("set is only allowed for the %s=<id> ownership stamp, got %q", nbOwnershipStampKey, args[2])
	}
	return nil
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

	// CommandTimeout bounds each individual ovn-nbctl invocation. Zero or
	// negative falls back to defaultNbctlTimeout. Overridable for tests.
	CommandTimeout time.Duration

	mu            sync.Mutex
	lastEndpoint  string
	lastSignature string
}

// defaultNbctlTimeout bounds each ovn-nbctl invocation. The replay runs
// synchronously inside the heartbeat loop (Heartbeater.PostSend →
// Manager.Reconcile), so a BLACKHOLED NB endpoint — host down, firewall
// drop — must never hold a command for the kernel's TCP timeout: that
// would delay the docker/k3s reconciles behind it and, at worst, make
// the node read presumed-dead. Enforced twice per command: ovn-nbctl's
// own `--timeout` (which fails the command cleanly), and a context
// deadline nbctlKillGrace later that SIGKILLs a client that ignored it.
const defaultNbctlTimeout = 15 * time.Second

// nbctlKillGrace is how long past --timeout the process gets before the
// context deadline kills it outright.
const nbctlKillGrace = 2 * time.Second

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
		if cmd == "set" {
			if err := validateNbSetCommand(c.Args); err != nil {
				return nil, fmt.Errorf("ovn nb apply: plan[%d]: %w", i, err)
			}
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
			CacheHit:        true,
		}, nil
	}

	// Prune pass (IMP-178a7e79fa0d) — BEFORE the replay, so a
	// false-positive delete of a still-desired row is repaired by this
	// very tick's replay. Guards (missing/empty manifest, missing
	// deployment id) live in pruneNb; failures are collected, reported,
	// and block the cache seed below — never silently skipped.
	pruneDeleted, pruneFailures, pruneAdopted := a.pruneNb(ctx, plan)

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
				PruneDeleted:    pruneDeleted,
				PruneFailed:     len(pruneFailures),
				LastPruneError:  strings.Join(pruneFailures, "; "),
			}
			return obs, fmt.Errorf("ovn nb apply: plan[%d] %s %v: %w", i, c.Cmd, c.Args, err)
		}
		applied++
	}

	obs := &ObservedOvnNbState{
		DeploymentID:    plan.DeploymentID,
		NbDbEndpoint:    plan.NbDbEndpoint,
		PlanCommands:    len(plan.Plan),
		AppliedCommands: applied,
		CompiledAt:      plan.CompiledAt,
		LastReplayAt:    nowRFC3339(),
		PruneDeleted:    pruneDeleted,
		PruneFailed:     len(pruneFailures),
		LastPruneError:  strings.Join(pruneFailures, "; "),
	}

	if len(pruneFailures) > 0 {
		// A failed delete is an ERROR observation. The replay half is
		// clean (LastError stays empty — the NB DB WAS positively
		// observed, which is what the platform's activation verdict
		// keys on), but Apply reports the failure and refuses to seed
		// the cache so the next tick retries the prune.
		return obs, fmt.Errorf("ovn nb prune: %d delete(s) failed: %s", len(pruneFailures), strings.Join(pruneFailures, "; "))
	}

	if !pruneAdopted {
		// The prune ran before some desired switches carried the
		// ownership stamp (first tick after upgrade, or a fresh NB DB) —
		// so it could not yet see the rows it exists to reap. The replay
		// above just stamped them; skipping the cache seed makes the next
		// tick prune against the adopted set instead of short-circuiting
		// forever on a byte-identical plan. Not an error: nothing failed.
		return obs, nil
	}

	a.mu.Lock()
	a.lastEndpoint = plan.NbDbEndpoint
	a.lastSignature = sig
	a.mu.Unlock()

	return obs, nil
}

// nbNormalizeMatch collapses whitespace runs so a desired ACL match
// survives comparison against ovn-nbctl's re-serialized form. (OVN
// pretty-prints the parsed expression; spacing is the only difference
// observed for platform-authored matches. A deeper canonicalization
// difference would cause a delete + same-tick re-add — churn, not
// policy loss, because the prune runs before the replay.)
func nbNormalizeMatch(m string) string {
	return strings.Join(strings.Fields(m), " ")
}

// nbAclListRe parses one `ovn-nbctl acl-list <switch>` line, e.g.
//
//	to-lport  1000 (ip4.src == 10.0.0.0/24) allow
//
// The match expression may itself contain parentheses, so `(.*)` is
// greedy and the action-word anchor disambiguates the closing paren.
var nbAclListRe = regexp.MustCompile(`^\s*(from-lport|to-lport)\s+(\d+)\s+\((.*)\)\s+(allow-related|allow-stateless|allow|drop|reject|pass)\b`)

// nbLspListRe parses one `ovn-nbctl lsp-list <switch>` line:
//
//	<uuid> (<port-name>)
var nbLspListRe = regexp.MustCompile(`^\s*[0-9a-fA-F-]+\s+\((.+)\)\s*$`)

// pruneNb deletes owned NB rows the desired-set manifest omits. Returns
// how many rows it deleted plus a failure message per item it could not
// prune (including rows it could not MEASURE — an unlistable switch or
// an unparseable list line is reported, never silently kept).
//
// Ownership scoping, the not-measured guards, delete ordering, and the
// honesty contract are documented in the file header.
// The third return (adopted) reports whether every desired switch was
// already ownership-stamped when the prune candidates were listed. On
// the FIRST tick after this fix ships, pre-existing switches are not
// yet stamped, so the prune sees nothing owned and skips exactly the
// pre-fix garbage this task exists to remove; the replay then stamps
// them. Returning adopted=false makes Apply skip the cache seed so the
// NEXT tick re-runs the prune against the now-stamped set instead of
// short-circuiting forever on a byte-identical plan.
func (a *ShellOvnNbApplier) pruneNb(ctx context.Context, plan *OvnNbPlan) (int, []string, bool) {
	ds := plan.DesiredSet
	// NOT MEASURED (nil manifest: old server payload) and the empty-set
	// guard (zero desired switches) both prune nothing — and there is
	// nothing to adopt, so the cache behaves as before. A deployment id
	// that fails the safe-name shape (blank, whitespace, or anything
	// outside [\w\-.]) would make the ownership find unscoped or
	// injectable — refuse to prune, and refuse the cache seed so this
	// never freezes into a steady state silently.
	if ds == nil || len(ds.Switches) == 0 {
		return 0, nil, true
	}
	if !nbSafeNameRe.MatchString(plan.DeploymentID) {
		return 0, nil, false
	}

	deleted := 0
	var failures []string

	// Prune candidates come ONLY from the ownership-stamped find. If
	// the listing itself fails we have measured nothing — delete
	// nothing, report the failure.
	out, err := a.runNbctl(ctx, plan.NbDbEndpoint,
		"--no-heading", "--data=bare", "--columns=name",
		"find", "Logical_Switch", nbOwnershipStampKey+"="+plan.DeploymentID)
	if err != nil {
		return 0, []string{fmt.Sprintf("list owned switches: %v", err)}, false
	}
	var owned []string
	for _, line := range strings.Split(out, "\n") {
		if name := strings.TrimSpace(line); name != "" {
			owned = append(owned, name)
		}
	}
	sort.Strings(owned)

	desiredSwitches := make(map[string]struct{}, len(ds.Switches))
	for _, s := range ds.Switches {
		desiredSwitches[s] = struct{}{}
	}

	ownedSet := make(map[string]struct{}, len(owned))
	for _, s := range owned {
		ownedSet[s] = struct{}{}
	}
	adopted := true
	for s := range desiredSwitches {
		if _, ok := ownedSet[s]; !ok {
			adopted = false
			break
		}
	}

	// Pass 1 — child deletes on SURVIVING owned switches: retracted
	// ACLs first (the security-relevant case — an over-permissive allow
	// must go regardless of what happens to any switch), then orphan
	// ports. Doomed switches are skipped here: their ls-del below
	// cascades ports + ACLs inside OVN.
	for _, sw := range owned {
		if _, want := desiredSwitches[sw]; !want {
			continue
		}
		deleted, failures = a.pruneAcls(ctx, plan, sw, deleted, failures)
		deleted, failures = a.prunePorts(ctx, plan, sw, deleted, failures)
	}

	// Pass 2 — owned switches the manifest omits. ls-del cascades the
	// switch's own ports and ACLs atomically; --if-exists makes the
	// concurrent-chassis race (another host already pruned it) benign.
	for _, sw := range owned {
		if _, want := desiredSwitches[sw]; want {
			continue
		}
		if _, err := a.runNbctl(ctx, plan.NbDbEndpoint, "--if-exists", "ls-del", sw); err != nil {
			failures = append(failures, fmt.Sprintf("ls-del %s: %v", sw, err))
			continue
		}
		deleted++
	}

	return deleted, failures, adopted
}

// pruneAcls removes ACLs on an owned, surviving switch that the
// manifest does not declare. Identity is (direction, priority) — unique
// among active platform ACLs — with the normalized match as the
// in-place-edit disambiguator: a listed row whose slot is desired but
// whose expression differs is stale and gets pruned (the replay re-adds
// the desired expression this same tick). Deletes address the row by
// the match text ovn-nbctl itself printed, which is the canonical form
// the NB DB will recognize.
func (a *ShellOvnNbApplier) pruneAcls(ctx context.Context, plan *OvnNbPlan, sw string, deleted int, failures []string) (int, []string) {
	out, err := a.runNbctl(ctx, plan.NbDbEndpoint, "acl-list", sw)
	if err != nil {
		return deleted, append(failures, fmt.Sprintf("acl-list %s: %v", sw, err))
	}

	type aclKey struct {
		dir   string
		prio  string
		match string
	}
	desired := make(map[aclKey]struct{})
	for _, want := range plan.DesiredSet.Acls[sw] {
		desired[aclKey{want.Direction, fmt.Sprintf("%d", want.Priority), nbNormalizeMatch(want.Match)}] = struct{}{}
	}

	for _, line := range strings.Split(out, "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		m := nbAclListRe.FindStringSubmatch(line)
		if m == nil {
			// A row we cannot parse is a row we cannot MEASURE — keep it,
			// but say so rather than silently skipping.
			failures = append(failures, fmt.Sprintf("acl-list %s: unparseable line %q", sw, strings.TrimSpace(line)))
			continue
		}
		dir, prio, match := m[1], m[2], m[3]
		if _, want := desired[aclKey{dir, prio, nbNormalizeMatch(match)}]; want {
			continue
		}
		if _, err := a.runNbctl(ctx, plan.NbDbEndpoint, "acl-del", sw, dir, prio, match); err != nil {
			failures = append(failures, fmt.Sprintf("acl-del %s %s %s: %v", sw, dir, prio, err))
			continue
		}
		deleted++
	}
	return deleted, failures
}

// prunePorts removes ports on an owned, surviving switch that the
// manifest does not declare for it. Port names are NB-global, so a port
// the manifest wants on a DIFFERENT switch is still an orphan here —
// lsp-del removes it and the replay re-adds it under the right parent.
func (a *ShellOvnNbApplier) prunePorts(ctx context.Context, plan *OvnNbPlan, sw string, deleted int, failures []string) (int, []string) {
	out, err := a.runNbctl(ctx, plan.NbDbEndpoint, "lsp-list", sw)
	if err != nil {
		return deleted, append(failures, fmt.Sprintf("lsp-list %s: %v", sw, err))
	}

	desired := make(map[string]struct{}, len(plan.DesiredSet.Ports[sw]))
	for _, name := range plan.DesiredSet.Ports[sw] {
		desired[name] = struct{}{}
	}

	for _, line := range strings.Split(out, "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		m := nbLspListRe.FindStringSubmatch(line)
		if m == nil {
			failures = append(failures, fmt.Sprintf("lsp-list %s: unparseable line %q", sw, strings.TrimSpace(line)))
			continue
		}
		name := m[1]
		if _, want := desired[name]; want {
			continue
		}
		if _, err := a.runNbctl(ctx, plan.NbDbEndpoint, "--if-exists", "lsp-del", name); err != nil {
			failures = append(failures, fmt.Sprintf("lsp-del %s: %v", name, err))
			continue
		}
		deleted++
	}
	return deleted, failures
}

// replayOne issues a single `ovn-nbctl --timeout=<secs> --db=<endpoint>
// [--may-exist] <cmd> <args...>`, bounded by a context deadline slightly
// past the --timeout. The subcommand is already allow-list-validated by
// the caller. Each arg is passed as a distinct argv element — no shell
// interpolation — so values containing spaces (e.g. an addresses string
// "02:.. 10.0.0.5") survive intact as one ovn-nbctl argument.
func (a *ShellOvnNbApplier) replayOne(ctx context.Context, endpoint string, c OvnNbCommand) error {
	cmd := strings.TrimSpace(c.Cmd)

	argv := make([]string, 0, len(c.Args)+2)
	if _, ok := nbMayExistCmds[cmd]; ok {
		argv = append(argv, "--may-exist")
	}
	argv = append(argv, cmd)
	argv = append(argv, c.Args...)

	_, err := a.runNbctl(ctx, endpoint, argv...)
	return err
}

// runNbctl issues a single `ovn-nbctl --timeout=<secs> --db=<endpoint>
// <args...>`, bounded by a context deadline slightly past the
// --timeout, and returns its stdout. Shared by the replay (which
// discards stdout) and the prune pass (whose find/lsp-list/acl-list
// reads consume it).
func (a *ShellOvnNbApplier) runNbctl(ctx context.Context, endpoint string, args ...string) (string, error) {
	timeout := a.CommandTimeout
	if timeout <= 0 {
		timeout = defaultNbctlTimeout
	}
	secs := int(timeout / time.Second)
	if secs < 1 {
		secs = 1
	}

	argv := make([]string, 0, len(args)+2)
	argv = append(argv, fmt.Sprintf("--timeout=%d", secs), "--db="+endpoint)
	argv = append(argv, args...)

	ctx, cancel := context.WithTimeout(ctx, timeout+nbctlKillGrace)
	defer cancel()

	command := exec.CommandContext(ctx, a.ovnNbctl(), argv...)
	// Without WaitDelay, Run blocks past the kill on the stdio pipes when a
	// grandchild inherited them (ovn-nbctl re-execing, a wrapper script) —
	// exactly the wedge the deadline exists to prevent.
	command.WaitDelay = nbctlKillGrace
	var stdout, stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	if err := command.Run(); err != nil {
		return "", fmt.Errorf("%w; stderr=%s", err, strings.TrimSpace(stderr.String()))
	}
	return stdout.String(), nil
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
	// The desired set participates in the signature (IMP-178a7e79fa0d):
	// a manifest change must invalidate the short-circuit even if the
	// command plan were byte-identical, or a retraction could be frozen
	// out by the cache. Maps are serialized in sorted-key order for a
	// stable fingerprint.
	if ds := plan.DesiredSet; ds != nil {
		b.WriteString("\x1ddesired\n")
		for _, s := range ds.Switches {
			b.WriteString(s)
			b.WriteByte('\x1e')
		}
		b.WriteByte('\n')
		portKeys := make([]string, 0, len(ds.Ports))
		for k := range ds.Ports {
			portKeys = append(portKeys, k)
		}
		sort.Strings(portKeys)
		for _, k := range portKeys {
			b.WriteString(k)
			b.WriteByte('\x1f')
			for _, pn := range ds.Ports[k] {
				b.WriteString(pn)
				b.WriteByte('\x1e')
			}
			b.WriteByte('\n')
		}
		aclKeys := make([]string, 0, len(ds.Acls))
		for k := range ds.Acls {
			aclKeys = append(aclKeys, k)
		}
		sort.Strings(aclKeys)
		for _, k := range aclKeys {
			b.WriteString(k)
			b.WriteByte('\x1f')
			for _, acl := range ds.Acls[k] {
				fmt.Fprintf(&b, "%s|%d|%s\x1e", acl.Direction, acl.Priority, acl.Match)
			}
			b.WriteByte('\n')
		}
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
