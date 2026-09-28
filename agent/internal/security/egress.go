package security

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/fsutil"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// EgressTable is the nftables table name the agent uses for module-level
// egress allowlists. Each module attached to the node gets its own chain
// inside this table so attach/detach is cleanly bounded.
const EgressTable = "powernode_module_egress"

// ApplyEgressAllowlist installs nftables rules implementing default-deny
// egress with explicit allow rules for each entry in the allowlist.
// Entries are "host:port" or "host" (port-agnostic).
//
// Empty allowlist = full block (no egress). Use a one-element wildcard
// (e.g., "0.0.0.0/0") to permit unrestricted egress; modules requesting
// this should be reviewed.
//
// Implementation notes:
//   - For DNS resolution, the entry "host" is resolved to A/AAAA records
//     at install time + on cert-rotate (which runs every ~67 days). This
//     is best-effort; long-lived modules whose endpoints rotate IPs will
//     need to handle DNS via a sidecar.
//   - The chain is replaced atomically per attach to avoid partial-state
//     egress windows during rollouts.
//   - `ct state established,related accept` is always the first rule so
//     responses to inbound connections survive (SSH SYN-ACK, federation
//     accept response, etc.). Without this the host appears network-dead
//     from the outside even though outbound to allowlist destinations
//     works.
//
// Compatibility shim — callers that don't yet pass protectedHosts get
// no auto-allowed destinations beyond the static lo+DNS+established
// triumvirate. Use ApplyEgressAllowlistWithProtected to specify hosts
// (typically the platform URL) that must always be reachable so the
// agent doesn't firewall itself off from its parent.
func ApplyEgressAllowlist(ctx context.Context, runner mount.Runner, allowlist []string) error {
	return ApplyEgressAllowlistWithProtected(ctx, runner, allowlist, nil)
}

// EgressExtras carries SDWAN-owned egress requirements the node-wide chain
// must allow, independent of any module's own egress_allow policy
// (IMP-13645c4df90a — the default-deny chain was dropping the WireGuard
// handshake outright: 296B sent, 0B received). See sdwan.Manager.
// EgressContributions, the producer on the other side of this seam — this
// package must not import internal/sdwan (a firewall primitive must not
// depend on one specific consumer's domain model), so EgressExtras is the
// narrow value type the reconciler passes across instead.
type EgressExtras struct {
	// Networks is one entry per desired SDWAN network — see EgressNetwork.
	Networks []EgressNetwork
}

// EgressNetwork is one SDWAN network's egress requirements. Two
// independent rules come out of one EgressNetwork (see buildEgressExtrasRules):
//
//  1. `udp sport <ListenPort> accept` (no oifname) — matches the OUTER
//     WireGuard UDP packets, which egress via whatever PHYSICAL route
//     reaches the peer, never via the wg-sdwan-* virtual device itself.
//     Only the kernel's own bound WG socket can emit a packet with this
//     source port, in EITHER direction (handshake initiation, keepalive,
//     rekey), so this is what lets the tunnel come up and stay up — a
//     per-peer daddr:port rule cannot: a hub has no fixed endpoint to dial a
//     NATed spoke once conntrack's `established,related` state expires, and
//     a daddr:port rule would let ANY local process send UDP to a
//     platform-controlled IP:port (PeerConf.Endpoint is writable by anyone
//     with SDWAN write on the account — 169.254.169.254 and an attacker's
//     own :443 are both syntactically valid entries).
//  2. `oifname <Interface> {ip|ip6} daddr { <AllowedIPs of this family> }
//     accept` — matches PLAINTEXT packets a local process routes INTO the
//     tunnel, scoped to exactly what wg_applier.go's `wg syncconf` actually
//     installs as this interface's crypto-routes (AllowedIPs). A blanket
//     `oifname X accept` would let a platform-pushed 0.0.0.0/0 or ::/0
//     AllowedIPs turn into unrestricted egress for every module on the
//     node routed through that interface — refused outright (skip + log),
//     never rendered as a rule.
type EgressNetwork struct {
	// Interface is this network's wg-sdwan-* device name.
	Interface string
	// ListenPort is this node's own WireGuard UDP listen port for
	// Interface. 0 (unset/random) is skipped and logged — see rule 1 above;
	// without a known port there is nothing safe to match on.
	ListenPort int
	// AllowedIPs is the union of this network's peers' AllowedIPs CIDRs
	// (PeerConf.AllowedIPs, raw/unparsed) — see rule 2 above. Duplicates
	// across peers are fine; buildEgressExtrasRules dedupes after parsing.
	AllowedIPs []string
}

// ApplyEgressAllowlistWithProtected is the full form. protectedHosts are
// destinations the agent MUST reach regardless of any single module's
// policy — typically the platform URL the agent connects to for control
// plane traffic. Without this, an empty module-egress allowlist would
// lock the agent out from its own parent on the very next reconcile tick
// (the agent applies the policy host-wide, including over its own
// outbound socket creation path).
//
// Each entry follows the same "host" or "host:port" shape as allowlist.
// Empty / nil protectedHosts = no extra allows beyond the static rules.
//
// Compatibility shim over ApplyEgressAllowlistWithExtras with EgressExtras{}
// — kept as its own function (rather than a variadic/optional param on the
// full form) so the three other production/test call sites of THIS exact
// signature (policy.go's doc reference, modules_client.go's doc reference,
// security_test.go, egress_injection_test.go, partial_manifest_guard_test.go)
// need no change for a concern (SDWAN) none of them has anything to do with.
func ApplyEgressAllowlistWithProtected(ctx context.Context, runner mount.Runner, allowlist, protectedHosts []string) error {
	return ApplyEgressAllowlistWithExtras(ctx, runner, allowlist, protectedHosts, EgressExtras{})
}

// ApplyEgressAllowlistWithExtras is ApplyEgressAllowlistWithProtected plus
// SDWAN's node-wide allowances (IMP-13645c4df90a). See EgressExtras/
// EgressNetwork's own doc for what these are and why they cannot go through
// the module-policy path (allowlist) or the protectedHosts path: a bare
// `udp sport` match has no destination at all, and a CIDR-SET-scoped
// `oifname` match needs UDP where module egress_allow entries have only ever
// needed a single TCP daddr — neither shape fits buildEgressRules' shared
// per-entry `emit` closure (see buildEgressExtrasRules' own doc for why this
// stays a separate emitter rather than a parameter bent onto the existing
// one).
//
// ATOMIC REBUILD (IMP-13645c4df90a, operator-scoped rework — review found the
// original per-rule-nft-call sequence had a live lockout bug: the
// protectedHosts loop below RETURNED on the first resolve/add failure,
// leaving a chain with only ct-state/lo/DNS installed — a chain that drops
// EVERYTHING else, including the agent's own control-plane traffic, until
// the next successful reconcile tick). The whole ruleset is now rendered as
// ONE nft script and applied with ONE `nft -f <path>` call — see
// renderEgressScript/applyEgressScript. That makes the old "delete chain
// then add chain" bootstrap (a window where the chain does not exist at
// all) and the old "install extras LAST so a per-rule failure there can't
// erase earlier rules" ordering both moot: `nft -f` is one netlink
// transaction, so either every statement in the script lands or NONE of
// them do and the kernel's prior chain is left exactly as it was — there is
// no partial-apply state for any ordering to protect against anymore. The
// rendered order below follows the approved plan (protectedHosts, then
// SDWAN extras, then the module allowlist) rather than the old
// last-installed-wins ordering, purely for readability of the emitted
// script — it has no safety implication either way under one transaction.
func ApplyEgressAllowlistWithExtras(ctx context.Context, runner mount.Runner, allowlist, protectedHosts []string, extras EgressExtras) error {
	script, problems, err := renderEgressScript(allowlist, protectedHosts, extras)
	if err != nil {
		return fmt.Errorf("egress allowlist: %w", err)
	}
	if err := applyEgressScript(ctx, runner, script); err != nil {
		if len(extras.Networks) == 0 {
			return err
		}
		// Defense-in-depth (review round, IMP-13645c4df90a item 4): extras
		// are additive and must NEVER hold a well-formed module/protected-
		// host ruleset hostage — including against a failure our own
		// validation could not have predicted (a kernel/nft-version quirk
		// in a rule shape only extras produce, not a grammar bug
		// renderEgressScript would already have caught). Re-render and
		// re-apply WITHOUT extras; if that succeeds, the module and
		// protected-host rules are live for this tick and only the extras
		// failure is reported.
		fallbackScript, fallbackProblems, rerr := renderEgressScript(allowlist, protectedHosts, EgressExtras{})
		if rerr != nil {
			// Unreachable in practice — the render that just succeeded ABOVE
			// already validated allowlist+protectedHosts; dropping extras only
			// removes lines, it cannot make grammar or DNS resolution that
			// already passed suddenly fail. Surface both rather than guess.
			return fmt.Errorf("egress: nft -f failed (%w) and the extras-free fallback render also failed: %v", err, rerr)
		}
		if aerr := applyEgressScript(ctx, runner, fallbackScript); aerr != nil {
			return fmt.Errorf("egress: nft -f failed both WITH sdwan extras (%v) and again WITHOUT them (%w) — no chain change was applied this tick", err, aerr)
		}
		problems = append(fallbackProblems, fmt.Sprintf("sdwan extras caused the atomic apply to fail and were dropped for this tick: %v", err))
		return fmt.Errorf("egress: %s", strings.Join(problems, "; "))
	}
	// Hostnames that did not resolve, and SDWAN extras that were malformed,
	// capped, or unresolvable, were SKIPPED at render time (not fatal — see
	// buildEgressRules F6 and buildEgressExtrasRules' own doc) and never
	// appear in the script at all. The resolvable/valid subset is already
	// installed (the nft -f above either fully applied or fully rolled
	// back); surface the skips so the reconciler logs them via OnError
	// without tearing down a working chain.
	if len(problems) > 0 {
		return fmt.Errorf("egress: %s", strings.Join(problems, "; "))
	}
	return nil
}

// egressScriptPath is the BASE path rendered nft scripts are staged under.
// A package var (not a const) so tests can redirect it into a temp
// directory instead of the real, root-only /run location. The file `nft -f`
// actually reads is NOT this path directly — see egressStagingPath.
var egressScriptPath = "/run/powernode-agent/egress.nft"

// SetEgressScriptPathForTest points the staged-script BASE path at path and
// returns a restore func — same seam shape as bootslots.SetEfivarsDirForTest
// et al. Exported so packages layered on ApplyEgressAllowlistWithExtras
// (runtime's reconciler tests, which drive it indirectly through RunOnce)
// can read back the actual rendered script (via EgressStagingPathForTest)
// rather than only inspecting the single `nft -f <path>` invocation a
// RecorderRunner records. Production code must never call this; nothing
// outside _test.go does.
func SetEgressScriptPathForTest(path string) (restore func()) {
	prev := egressScriptPath
	egressScriptPath = path
	return func() { egressScriptPath = prev }
}

// EgressStagingPathForTest returns the exact file THIS process's next apply
// will stage its script at — the same derivation applyEgressScript uses
// internally. Exported purely so a test that redirected egressScriptPath
// can find the file to read back; production code calls the unexported
// egressStagingPath directly.
func EgressStagingPathForTest() string { return egressStagingPath() }

// egressStagingPath derives THIS PROCESS's own staging file from
// egressScriptPath: "<dir>/<base>.<pid><ext>", e.g.
// "/run/powernode-agent/egress.418271.nft". A per-process filename (review
// round, IMP-13645c4df90a item 2) — the base path alone is shared by every
// process that can reach ApplyEgressAllowlistWithExtras (the long-running
// service, and formerly any CLI invocation before SkipEgress existed —
// kept anyway as defense-in-depth against a leftover process during a
// service restart, or any future caller), and two processes racing to
// write + `nft -f` the SAME inode is a real hazard fsutil.AtomicWrite's
// tmp-then-rename does not fully close: rename is atomic per-write, but
// nothing stops process B's rename from landing between process A's
// rename and process A's own `nft -f` open, so A could apply B's script
// (or vice versa). A distinct path per process makes that structurally
// impossible; applyEgressScript removes its own file after the `nft -f`
// call regardless of outcome, so nothing accumulates in the staging dir.
func egressStagingPath() string {
	dir := filepath.Dir(egressScriptPath)
	ext := filepath.Ext(egressScriptPath)
	base := strings.TrimSuffix(filepath.Base(egressScriptPath), ext)
	return filepath.Join(dir, fmt.Sprintf("%s.%d%s", base, os.Getpid(), ext))
}

// egressChain is the single chain name every rule in the rendered script
// targets — one per node (not per module: see EgressTable's own doc).
const egressChain = "powernode_egress_filter"

// renderEgressScript is the PURE half of the atomic rebuild: it validates
// and resolves everything (allowlist grammar + DNS, protectedHosts DNS,
// SDWAN extras) and returns the complete nft script text, doing no I/O of
// its own beyond the DNS lookups buildEgressRules/resolveProtectedHost
// already performed pre-rework. Splitting render from apply (below) is what
// makes the "protected-host resolve failure aborts BEFORE any nft call"
// property structural rather than a call-ordering convention: render never
// touches the runner, so a resolve failure returning an error here can
// never have already caused any nft mutation.
//
// problems is a single combined, human-readable list of everything that was
// SKIPPED (never a hard abort — see buildEgressRules/buildEgressExtrasRules
// for which failures are fatal here vs. skip-and-log). script is "" and
// err != nil for anything fatal (grammar violation, a protected host that
// will not resolve, or a rendered script that fails the final line-grammar
// guard); a caller must not apply an empty script for a fatal error.
func renderEgressScript(allowlist, protectedHosts []string, extras EgressExtras) (script string, problems []string, err error) {
	// Validate + resolve the whole allowlist first. A grammar violation
	// (whitespace, ';', a newline, a brace) must never reach the script text,
	// since nft -f re-parses the file the same way it re-parses joined argv —
	// a single hostile line can smuggle a second statement into this
	// NODE-WIDE chain's transaction. Fail closed: no script is produced.
	rules, skippedAllow, err := buildEgressRules(allowlist)
	if err != nil {
		return "", nil, err
	}
	// Protected hosts resolve exactly as before (IP-literal rules only —
	// nft does not expand hostnames at load time; see the doc history a few
	// lines below at the loop). A resolve failure is fatal — see
	// ApplyEgressAllowlistWithProtected's own doc for why an unreachable
	// protected host must never allow silently-incomplete convergence.
	protectedLines, err := renderProtectedHostLines(protectedHosts)
	if err != nil {
		return "", nil, err
	}
	// Extras get the SAME "resolve/validate before touching the script"
	// treatment, but NOT the same fail-closed verdict: these values are
	// agent-computed from typed platform JSON, not operator-authored
	// manifest text, so a malformed one is far more likely a data/versioning
	// bug than an injection attempt, and it is ADDITIVE to an otherwise-
	// independent module policy — skip-and-log, never abort. See
	// buildEgressExtrasRules' own doc.
	extraRules, skippedExtras := buildEgressExtrasRules(extras)

	var b strings.Builder
	fmt.Fprintf(&b, "add table inet %s\n", EgressTable)
	// `add chain` with an explicit hook spec is idempotent across repeated
	// applies as long as the spec never changes (which it doesn't — this is
	// a constant), so first-install and every steady-state reconcile use the
	// exact same script; there is no separate bootstrap path to drift from
	// steady state.
	fmt.Fprintf(&b, "add chain inet %s %s { type filter hook output priority 0 ; policy drop ; }\n", EgressTable, egressChain)
	// `flush` empties whatever rules a PRIOR apply left in the chain (a
	// freshly created chain is already empty, so this is a harmless no-op on
	// first install) — this is what replaces the old delete-then-add
	// bootstrap, without ever leaving the chain absent.
	fmt.Fprintf(&b, "flush chain inet %s %s\n", EgressTable, egressChain)

	writeRule := func(tokens ...string) {
		fmt.Fprintf(&b, "add rule inet %s %s %s\n", EgressTable, egressChain, strings.Join(tokens, " "))
	}
	// Allow outbound responses for connections initiated against us (inbound
	// SSH/HTTP/etc). Without this, the OUTPUT hook drops every SYN-ACK +
	// reply packet, making the host look network-dead from the outside even
	// though it can still initiate outbound to allowlisted destinations.
	// First rule so the conntrack lookup happens before any allowlist match.
	writeRule("ct", "state", "established,related", "accept")
	// Always allow loopback + DNS (modules that don't allow DNS can't
	// resolve their own permitted hosts).
	writeRule("oif", "lo", "accept")
	writeRule("udp", "dport", "53", "accept")
	writeRule("tcp", "dport", "53", "accept")
	for _, line := range protectedLines {
		writeRule(line...)
	}
	for _, rule := range extraRules {
		writeRule(rule...)
	}
	for _, rule := range rules {
		writeRule(rule...)
	}

	rendered := b.String()
	if err := validateEgressScriptGrammar(rendered); err != nil {
		// Should be unreachable given the per-entry character screens above —
		// this is the production fail-closed backstop the plan calls for, not
		// the primary defense.
		return "", nil, fmt.Errorf("egress: rendered script failed its own grammar guard: %w", err)
	}

	if len(skippedAllow) > 0 {
		problems = append(problems, fmt.Sprintf("%d allowlist hostname(s) did not resolve and were skipped: %q", len(skippedAllow), skippedAllow))
	}
	if len(skippedExtras) > 0 {
		problems = append(problems, fmt.Sprintf("%d sdwan extra(s) were invalid, capped, or did not resolve and were skipped: %q", len(skippedExtras), skippedExtras))
	}
	return rendered, problems, nil
}

// renderProtectedHostLines resolves protectedHosts to nft rule tokens (see
// ApplyEgressAllowlistWithProtected's doc for why these must always be
// IP literals, never a bare hostname operand). A resolve failure is
// returned immediately — this is what makes "protected-host resolve
// failure aborts before any nft call" true unconditionally, not merely
// true because of where this happens to be called from: this function
// performs no I/O against nft at all.
func renderProtectedHostLines(protectedHosts []string) (lines [][]string, err error) {
	for _, host := range protectedHosts {
		host = strings.TrimSpace(host)
		if host == "" {
			continue
		}
		ips, err := resolveProtectedHost(host)
		if err != nil {
			return nil, fmt.Errorf("egress protected-host %q: %w", host, err)
		}
		for _, ip := range ips {
			lines = append(lines, []string{ipFamily(ip), "daddr", ip.String(), "accept"})
		}
	}
	return lines, nil
}

// egressScriptLineCharset is the final, whole-script fail-closed guard the
// plan requires (production defense-in-depth, reused directly by tests —
// see validateEgressScriptGrammar). It is deliberately narrower than
// egressDisallowedChars (which only EXCLUDES known-hostile characters from
// one raw entry): this is an ALLOWLIST of every character any line of a
// well-formed script can legitimately contain — letters/digits (hostnames,
// interface names, keywords), space (token separator), '.' ':' '/' (IPs and
// CIDRs), ',' (nft set-literal separator), '{' '}' (set literals and the
// chain-definition block), '"' (quoted interface names), '_' '-' (table/
// chain/interface names).
var egressScriptLineCharset = regexp.MustCompile(`^[A-Za-z0-9 .:/,{}"_-]*$`)

// egressScriptRulePrefix is the fixed prefix EVERY rule line the renderer
// emits shares — writeRule (in renderEgressScript) never composes a line
// any other way. Exported as a named constant so the structural guard below
// can require it exactly rather than merely "passes a charset".
const egressScriptRulePrefix = "add rule inet " + EgressTable + " " + egressChain + " "

// egressScriptHeaderLines are the exact three lines renderEgressScript
// always emits before any rule, in this order, byte for byte — see the
// three fmt.Fprintf calls at its start. Any deviation (missing, reordered,
// or a THIRD candidate impersonating one of these) is refused.
var egressScriptHeaderLines = []string{
	"add table inet " + EgressTable,
	"add chain inet " + EgressTable + " " + egressChain + " { type filter hook output priority 0 ; policy drop ; }",
	"flush chain inet " + EgressTable + " " + egressChain,
}

// validateEgressScriptGrammar is the STRUCTURAL, whole-script fail-closed
// guard the plan requires (review round, IMP-13645c4df90a item 6) —
// production defense-in-depth, reused directly by tests. It is deliberately
// NOT just "every line passes a charset": the first three non-empty lines
// must be EXACTLY egressScriptHeaderLines, in order (the only place a
// semicolon is legitimate nft syntax — it separates the hook-spec clauses
// inside the chain-definition block — so ';' is checked by full-line
// EQUALITY there, never charset-exempted more broadly), and every line
// after that must both START WITH egressScriptRulePrefix and have its
// REMAINDER pass egressScriptLineCharset. A line that merely happens to
// contain allowed characters but does not target this exact table/chain, or
// a header line that is subtly rewritten, is refused even though a
// charset-only check would have accepted it.
func validateEgressScriptGrammar(script string) error {
	var lines []string
	for _, line := range strings.Split(script, "\n") {
		if line != "" {
			lines = append(lines, line)
		}
	}
	if len(lines) < len(egressScriptHeaderLines) {
		return fmt.Errorf("script has %d line(s), fewer than the %d required header lines", len(lines), len(egressScriptHeaderLines))
	}
	for i, want := range egressScriptHeaderLines {
		if lines[i] != want {
			return fmt.Errorf("header line %d must be exactly %q, got %q", i+1, want, lines[i])
		}
	}
	for i, line := range lines[len(egressScriptHeaderLines):] {
		rest, ok := strings.CutPrefix(line, egressScriptRulePrefix)
		if !ok {
			return fmt.Errorf("rule line %d does not start with %q: %q", i+1, egressScriptRulePrefix, line)
		}
		if !egressScriptLineCharset.MatchString(rest) {
			return fmt.Errorf("rule line %d contains a disallowed character: %q", i+1, line)
		}
	}
	return nil
}

// applyEgressScript is the I/O half of the atomic rebuild: it stages the
// already-validated script at egressScriptPath (write-tmp-then-rename, via
// fsutil.AtomicWrite, so a concurrent reader — there is none today, but this
// matches every other root-owned state file the agent writes — never sees a
// half-written file) and runs it as one `nft -f` transaction. mount.Runner
// has no stdin-piping method usable here (see mount.Runner's own doc: only
// StdinRunner pipes, and `nft -f -` needs stdin, not a Runner test double),
// hence a real file + `-f <path>` rather than `-f -`; this mirrors
// sdwan/nftables_applier.go's own ApplyRuleset, which reached the same
// `nft -f <tempfile>` shape independently for the identical reason.
// egressForceCleanupForTest overrides the testing.Testing() exemption inside
// applyEgressScript for the one test that verifies the staged file really
// is removed after apply — every other test relies on the exemption to
// read the file back, so this defaults false and must be restored promptly.
var egressForceCleanupForTest = false

// SetEgressForceCleanupForTest flips egressForceCleanupForTest and returns a
// restore func — same seam shape as SetEgressScriptPathForTest. Test-only;
// production code never calls this (the cleanup it forces on is otherwise
// unconditional there already).
func SetEgressForceCleanupForTest(v bool) (restore func()) {
	prev := egressForceCleanupForTest
	egressForceCleanupForTest = v
	return func() { egressForceCleanupForTest = prev }
}

func applyEgressScript(ctx context.Context, runner mount.Runner, script string) error {
	dir := filepath.Dir(egressScriptPath)
	if err := ensureEgressScriptDir(dir); err != nil {
		return fmt.Errorf("egress script dir %s: %w", dir, err)
	}
	path := egressStagingPath()
	if err := fsutil.AtomicWrite(path, []byte(script), 0o600); err != nil {
		return fmt.Errorf("write egress script %s: %w", path, err)
	}
	// Removed after apply regardless of outcome (review round item 2) — a
	// per-process file left behind indefinitely is unnecessary clutter under
	// the root-only staging dir, though not itself a hazard (the next apply
	// from this same process overwrites it via the same atomic rename).
	// EXEMPT under `go test` BY DEFAULT: every OTHER test that redirects
	// egressScriptPath reads the staged file back afterward
	// (readEgressScript, EgressStagingPathForTest) to assert on the
	// rendered script — the same testing.Testing() exemption
	// ensureEgressScriptDir's uid-0 check uses, for the same reason (a test
	// binary is never the real agent process this cleanup is for).
	// egressForceCleanupForTest (default false) is the one escape hatch: a
	// single test needs to observe the cleanup ITSELF actually happening.
	if !testing.Testing() || egressForceCleanupForTest {
		defer os.Remove(path)
	}
	if err := runner.Run(ctx, "nft", "-f", path); err != nil {
		return fmt.Errorf("nft -f %s: %w", path, err)
	}
	return nil
}

// ensureEgressScriptDir verifies (or creates) the staging directory a script
// is about to be written into — root-only (/run/powernode-agent in
// production), so its integrity matters: an attacker who can pre-create a
// SYMLINK there (e.g. pointing /run/powernode-agent at /etc) could redirect
// the write's target entirely, and an attacker who can pre-create it as a
// directory owned by a NON-ROOT uid could plant or swap files this process
// (root) then treats as trusted. Missing is the ordinary first-boot case
// (create it fresh, 0700). Present is checked, not trusted: refuse a
// symlink outright, refuse anything that isn't a plain directory, refuse
// one not owned by uid 0, and (re)assert 0700 on every apply — a mode drift
// from some other write is not silently trusted either.
func ensureEgressScriptDir(dir string) error {
	fi, err := os.Lstat(dir)
	if errors.Is(err, os.ErrNotExist) {
		return os.MkdirAll(dir, 0o700)
	}
	if err != nil {
		return err
	}
	if fi.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("%s is a symlink, refusing to stage the egress script there", dir)
	}
	if !fi.IsDir() {
		return fmt.Errorf("%s exists and is not a directory", dir)
	}
	// The uid-0 check is skipped under `go test` (same testing.Testing()
	// guard as mac.go's SetSystemdDropInRootForTest et al.): every test
	// redirects egressScriptPath into a t.TempDir(), which is owned by the
	// test process's own (non-root) uid — there is no real production
	// bypass here, since a test binary is never the agent process this
	// check protects. The symlink/is-a-directory checks above still apply
	// either way; only the OWNER identity is test-exempt.
	if st, ok := fi.Sys().(*syscall.Stat_t); ok && st.Uid != 0 && !testing.Testing() {
		return fmt.Errorf("%s is owned by uid %d, not root; refusing to stage the egress script there", dir, st.Uid)
	}
	return os.Chmod(dir, 0o700)
}

// egressEntryPattern excludes every character that could split an nft command
// or smuggle a token: whitespace, quotes, ';', '#', braces, '%' (zone-ids are
// contract-refused), and '\'. It is a coarse pre-filter; buildEgressRules does
// the structural parse. Kept deliberately strict — the contract grammar has no
// legitimate use for any excluded character.
var egressDisallowedChars = " \t\n\r\v\f;#{}%\"'`\\"

// buildEgressRules validates each allowlist entry against the SECURITY-BLOCK
// CONTRACT grammar (hostname | hostname:port | IP | prefix-form CIDR) and
// returns the nft rule fragments (each a []string of argv elements to append
// after the chain name). A hostname is resolved to IP literals here — the same
// treatment protectedHosts already get — because nft does not expand hostnames
// at rule-load time (egress.go documents the silent-failure history). Any entry
// that violates the grammar is a hard error; NO partial rule set is returned.
func buildEgressRules(allowlist []string) (rules [][]string, skipped []string, err error) {
	if len(allowlist) > maxEgressEntries {
		return nil, nil, fmt.Errorf("%d entries exceeds the %d-entry cap", len(allowlist), maxEgressEntries)
	}
	// Two-phase, because the two failure modes deserve opposite treatment:
	//
	//   GRAMMAR violation (whitespace, ';', a newline, a brace, an out-of-range
	//   port, a netmask CIDR, a zone-id) is HOSTILE or malformed — it is the
	//   injection surface — so ANY such entry aborts the whole apply BEFORE a
	//   single nft rule is emitted. Fatal.
	//
	//   DNS non-resolution of an otherwise-valid hostname is TRANSIENT /
	//   environmental — one module's flaky endpoint must NOT freeze egress-policy
	//   convergence for every sibling on the node (which returning a hard error
	//   here would, since the reconciler applies the union in one call — review
	//   finding F6). Such an entry is skipped and reported, not fatal.
	//
	// Phase 1: grammar-validate + parse every entry with NO DNS. Any error aborts.
	type parsed struct {
		raw      string
		host     string // non-empty => needs DNS resolution
		port     int
		literals []egressDaddr // IP/CIDR: emit directly, no DNS
	}
	items := make([]parsed, 0, len(allowlist))
	for _, raw := range allowlist {
		entry := strings.TrimSpace(raw)
		if entry == "" {
			continue
		}
		if strings.ContainsAny(entry, egressDisallowedChars) {
			return nil, nil, fmt.Errorf("entry %q contains a disallowed character (no whitespace, quotes, ';', '#', braces, '%%' zone-id, or backslash)", raw)
		}
		host, port, literals, perr := parseEgressGrammar(entry)
		if perr != nil {
			return nil, nil, fmt.Errorf("entry %q: %w", raw, perr)
		}
		items = append(items, parsed{raw: raw, host: host, port: port, literals: literals})
	}
	// Phase 2: emit rules; resolve hostnames best-effort.
	emit := func(daddrs []egressDaddr, port int) {
		for _, d := range daddrs {
			rule := []string{d.family, "daddr", d.addr}
			if port > 0 {
				rule = append(rule, "tcp", "dport", strconv.Itoa(port))
			}
			rule = append(rule, "accept")
			rules = append(rules, rule)
		}
	}
	for _, it := range items {
		if it.host == "" {
			emit(it.literals, it.port)
			continue
		}
		ips, rerr := egressResolveHost(it.host)
		if rerr != nil || len(ips) == 0 {
			skipped = append(skipped, it.raw)
			continue
		}
		daddrs := make([]egressDaddr, 0, len(ips))
		for _, ip := range ips {
			daddrs = append(daddrs, egressDaddr{family: ipFamily(ip), addr: ip.String()})
		}
		emit(daddrs, it.port)
	}
	return rules, skipped, nil
}

type egressDaddr struct {
	family string // "ip" | "ip6"
	addr   string // IP literal or prefix-form CIDR
}

// ipFamily reports the nft address family for a bare IP literal (never a
// CIDR — see egressCanonicalCIDR for that path). net.IP always stores an
// IPv4 address internally in its 16-byte, IPv4-mapped form, so a Go-level
// net.IP alone cannot distinguish "the caller wrote 1.2.3.4" from "the
// caller wrote ::ffff:1.2.3.4" — the two ARE the same bytes, and Unmap()
// correctly normalizes either spelling to Is4()==true. Unlike
// egressCanonicalCIDR's CIDR path, a bare mapped literal is not refused
// here: there is no prefix-length ambiguity for a single address (an
// AllowedIPs-style "the whole v4 space under a narrow-looking mask" bypass
// cannot arise for a /32-equivalent single host), so classifying it
// correctly is sufficient.
func ipFamily(ip net.IP) string {
	if addr, ok := netip.AddrFromSlice(ip); ok {
		if addr.Unmap().Is4() {
			return "ip"
		}
		return "ip6"
	}
	// Unexpected byte length for a net.IP (should not happen for anything
	// this package hands it) — fall back to the old heuristic rather than
	// silently mis-tagging.
	if ip.To4() != nil {
		return "ip"
	}
	return "ip6"
}

// wgSdwanIfaceMaxLen is Linux's IFNAMSIZ usable budget (16 bytes including
// the trailing NUL) — mirrors host_vrf_assignment.rb's VRF_NAME_MAX. NOT
// baked into wgSdwanIfacePattern as a `{1,N}` quantifier: the task brief's
// suggested pattern, `^wg-sdwan-[A-Za-z0-9]{1,15}$`, bounds the SUFFIX at 15
// chars — but the fixed "wg-sdwan-" prefix is already 9 chars, so a 15-char
// suffix would total 24, well past IFNAMSIZ. Verified against
// the two real producers (host_vrf_assignment.rb#wg_iface_name: "wg-sdwan-"
// + an integer short_id, 1-9999; Sdwan::Network#network_handle: "wg-sdwan-"
// + exactly 6 lowercase hex chars) rather than trusting the suggested regex
// verbatim — both fit comfortably inside the real 6-char suffix budget this
// length check enforces, independent of the pattern.
const wgSdwanIfaceMaxLen = 15

// wgSdwanIfacePattern matches the wg-sdwan-* device-name SHAPE (alnum suffix
// only — no wildcard, no path separator, nothing an oifname argv element
// could smuggle). wgSdwanIfaceMaxLen enforces the real length budget
// separately (see its own doc).
var wgSdwanIfacePattern = regexp.MustCompile(`^wg-sdwan-[A-Za-z0-9]+$`)

func validWgSdwanIfaceName(name string) bool {
	return len(name) <= wgSdwanIfaceMaxLen && wgSdwanIfacePattern.MatchString(name)
}

// buildEgressExtrasRules validates an EgressExtras into nft rule fragments
// (review-round redesign, IMP-13645c4df90a) — but a malformed entry here is
// SKIPPED and reported, never a hard abort (see ApplyEgressAllowlistWithExtras'
// doc for why SDWAN extras and the module allowlist get different verdicts
// on a bad entry). Returns the rule fragments and a labelled skip list
// ("network <iface>: <reason>") for the caller's single error report.
//
// Deliberately separate from buildEgressRules rather than a parameter bent
// onto it: neither rule shape here (a bare `udp sport` match with no
// destination at all; an `oifname` + CIDR-SET daddr match) exists on the
// module-allowlist side, which buildEgressRules' shared per-entry `emit`
// closure is built around (a single daddr, optional TCP dport).
func buildEgressExtrasRules(extras EgressExtras) (rules [][]string, skipped []string) {
	networks := extras.Networks
	if len(networks) > maxEgressEntries {
		skipped = append(skipped, fmt.Sprintf("sdwan: %d network(s) exceeds the %d-entry cap; %d truncated",
			len(networks), maxEgressEntries, len(networks)-maxEgressEntries))
		networks = networks[:maxEgressEntries]
	}

	// Two (or more) SDWAN networks can share the same node-wide WireGuard
	// ListenPort — the kernel socket the sport rule matches on is bound once
	// per port, not once per network, so a second identical `udp sport N
	// accept` line would be a no-op duplicate in the rendered script, not a
	// second, independently-meaningful rule. Emit each distinct port once.
	seenPorts := make(map[int]struct{}, len(networks))

	for _, en := range networks {
		iface := strings.TrimSpace(en.Interface)
		label := iface
		if label == "" {
			label = "(unnamed)"
		}

		// Rule 1: udp sport <ListenPort> accept — see EgressNetwork's doc for
		// why this, not a per-peer daddr:port rule, and why no oifname here
		// (the outer WG packet's egress device is the physical route to the
		// peer, never the wg-sdwan-* virtual interface).
		switch {
		case en.ListenPort == 0:
			skipped = append(skipped, fmt.Sprintf("network %q: listen_port is unset (0), skipped", label))
		case en.ListenPort < 0 || en.ListenPort > 65535:
			skipped = append(skipped, fmt.Sprintf("network %q: listen_port %d is not 1-65535, skipped", label, en.ListenPort))
		default:
			if _, dup := seenPorts[en.ListenPort]; !dup {
				seenPorts[en.ListenPort] = struct{}{}
				rules = append(rules, []string{"udp", "sport", strconv.Itoa(en.ListenPort), "accept"})
			}
		}

		// Rule 2: oifname <iface> {ip|ip6} daddr { CIDRs } accept — scoped to
		// this network's peers' actual AllowedIPs. Skip the whole rule (not
		// just the interface) when the name itself doesn't pass — an invalid
		// oifname value is exactly the kind of thing that must never reach
		// argv, regardless of whether any CIDR would have been valid.
		if !validWgSdwanIfaceName(iface) {
			skipped = append(skipped, fmt.Sprintf("network interface %q: not a valid wg-sdwan-* name, skipped", iface))
			continue
		}

		v4, v6 := splitEgressCIDRs(en.AllowedIPs, iface, &skipped)
		if len(v4) > 0 {
			rules = append(rules, tunnelScopeRule("ip", iface, v4))
		}
		if len(v6) > 0 {
			rules = append(rules, tunnelScopeRule("ip6", iface, v6))
		}
	}
	return rules, skipped
}

// egressAllowedIPsMaxPerNetwork caps how many AllowedIPs CIDRs ONE network's
// tunnel-scope rule renders (plan item, review round) — a peer list that
// grows unbounded (a hub with many spokes, or a misbehaving platform push)
// must not turn into an unbounded set literal; the excess is truncated and
// the count logged, the same shape as maxEgressEntries elsewhere in this
// file.
const egressAllowedIPsMaxPerNetwork = 256

// splitEgressCIDRs parses + validates one network's raw AllowedIPs into
// canonical, de-duplicated, family-split CIDR strings, capped at
// egressAllowedIPsMaxPerNetwork per family. Every emitted CIDR is
// egressCanonicalCIDR's own canonical form, never the raw platform string —
// the same "never the attacker's own bytes" discipline buildEgressRules
// already applies to resolved hostnames. A minimum prefix length (v4 /8,
// v6 /16 — review round, IMP-13645c4df90a item 1) is refused alongside the
// IPv4-mapped-IPv6 rejection egressCanonicalCIDR itself does: a /0 is the
// obvious "unrestricted" case, but so is any near-/0 split (0.0.0.0/1 +
// 128.0.0.0/1 together cover the whole v4 space while each individually
// clears a bare "reject exactly /0" check) — refusing everything shorter
// than the minimum closes the whole class, not just the single literal.
func splitEgressCIDRs(raw []string, iface string, skipped *[]string) (v4, v6 []string) {
	seen := make(map[string]struct{}, len(raw))
	truncatedV4, truncatedV6 := 0, 0
	for _, r := range raw {
		cidr := strings.TrimSpace(r)
		if cidr == "" {
			continue
		}
		if strings.ContainsAny(cidr, egressDisallowedChars) {
			*skipped = append(*skipped, fmt.Sprintf("network %q allowed_ips %q: disallowed character, skipped", iface, r))
			continue
		}
		prefix, ok, reason := egressCanonicalCIDR(cidr)
		if !ok {
			*skipped = append(*skipped, fmt.Sprintf("network %q allowed_ips %q: %s, skipped", iface, r, reason))
			continue
		}
		addr, bits := prefix.Addr(), prefix.Bits()
		minBits := 8
		if addr.Is6() {
			minBits = 16
		}
		if bits < minBits {
			*skipped = append(*skipped, fmt.Sprintf(
				"network %q allowed_ips %q: a /%d CIDR is narrower than the minimum /%d, refused", iface, r, bits, minBits))
			continue
		}
		canon := prefix.String()
		if _, dup := seen[canon]; dup {
			continue
		}
		seen[canon] = struct{}{}
		if addr.Is6() {
			if len(v6) >= egressAllowedIPsMaxPerNetwork {
				truncatedV6++
				continue
			}
			v6 = append(v6, canon)
		} else {
			if len(v4) >= egressAllowedIPsMaxPerNetwork {
				truncatedV4++
				continue
			}
			v4 = append(v4, canon)
		}
	}
	if truncatedV4 > 0 {
		*skipped = append(*skipped, fmt.Sprintf(
			"network %q: %d ipv4 allowed_ips beyond the %d-entry cap were truncated", iface, truncatedV4, egressAllowedIPsMaxPerNetwork))
	}
	if truncatedV6 > 0 {
		*skipped = append(*skipped, fmt.Sprintf(
			"network %q: %d ipv6 allowed_ips beyond the %d-entry cap were truncated", iface, truncatedV6, egressAllowedIPsMaxPerNetwork))
	}
	return v4, v6
}

// egressCanonicalCIDR parses cidr with net/netip rather than net.ParseCIDR +
// net.IP.To4 — the combination this replaces cannot reliably tell an
// IPv4-MAPPED IPv6 address (::ffff:a.b.c.d) apart from a genuine IPv4
// address (To4() reports true for both), which let a mapped CIDR like
// "::ffff:0:0/96" (every IPv4-mapped address — the entire v4 space) get
// classified "ip" while a later stage still held IPv6-shaped text, either
// rendering an unrestricted daddr set under a /0-looking guise (item 1) or
// producing a line nft rejects outright, failing the WHOLE atomic apply
// every tick (item 3). netip.Addr.Is4In6 checks the address's OWN wire
// pattern BEFORE any masking is applied — checking after Masked() would let
// a mask short enough to zero part of the fixed ::ffff:0:0/96 signature
// itself evade detection, so the mapped check runs first, deliberately.
// IPv4-mapped input is refused OUTRIGHT (not reinterpreted as plain IPv4):
// the caller almost certainly meant something specific by writing it in
// mapped form, and silently reclassifying it is the exact confusion being
// removed. Returns the canonical (Masked, then Unmap'd) netip.Prefix for
// anything accepted; ok=false with a human-readable reason for anything
// refused (not a CIDR, or IPv4-mapped). Callers apply their OWN minimum
// prefix-length policy on top — splitEgressCIDRs refuses short SDWAN
// prefixes, but a module's egress_allow "0.0.0.0/0" wildcard is a
// deliberately supported, human-reviewed contract entry (see this file's
// top-of-file doc), so parseEgressGrammar does not.
func egressCanonicalCIDR(cidr string) (prefix netip.Prefix, ok bool, reason string) {
	p, err := netip.ParsePrefix(cidr)
	if err != nil {
		return netip.Prefix{}, false, "not a CIDR"
	}
	if p.Addr().Is4In6() {
		return netip.Prefix{}, false, "an IPv4-mapped IPv6 CIDR is refused"
	}
	addr := p.Masked().Addr().Unmap()
	return netip.PrefixFrom(addr, p.Bits()), true, ""
}

// tunnelScopeRule renders `oifname "<iface>" <family> daddr { c1, c2, ... }
// accept`. The interface name is double-quoted per the approved plan — it is
// going into a single script LINE now (rendered by renderEgressScript, not
// passed as separate argv elements to exec), so quoting is what pins it as
// one nft token regardless of what nft's own tokenizer would otherwise do
// with an unquoted bareword; it is safe to quote unconditionally because
// validWgSdwanIfaceName has already restricted iface to `[A-Za-z0-9-]`
// (checked by the caller before this is ever invoked), so it can never
// itself contain a quote to escape out of. A trailing comma is appended to
// each CIDR (nft tolerates a trailing comma before the closing brace) so the
// set's comma-separated grammar is satisfied without ever concatenating two
// values into one token — cidrs are already net.ParseCIDR's own canonical
// output by the time they reach here (splitEgressCIDRs), never raw platform
// text.
func tunnelScopeRule(family, iface string, cidrs []string) []string {
	rule := []string{"oifname", `"` + iface + `"`, family, "daddr", "{"}
	for _, c := range cidrs {
		rule = append(rule, c+",")
	}
	return append(rule, "}", "accept")
}

// classifyEgressEntry parses one already-char-screened entry into the nft
// destinations + optional TCP port it authorises. It accepts exactly the
// contract grammar and rejects everything else (fail closed):
//
//   - a bare IP literal (v4/v6)                  -> one daddr, family by literal
//   - a prefix-form CIDR ("0.0.0.0/0", "::/0")   -> one daddr; netmask-form
//     ("10.0.0.0/255.0.0.0") is refused because net.ParseCIDR rejects it
//   - a hostname (RFC-1123) or hostname:port     -> resolved to A/AAAA literals
//
// An out-of-range or non-numeric port is an ERROR — never folded back into the
// host operand (the pre-fix parseEgressEntry bug that laundered "host:port"
// text straight into `ip daddr <text>`).
// parseEgressGrammar validates ONE already-char-screened entry against the
// contract grammar WITHOUT any DNS. It returns exactly one of:
//   - literals != nil, host == "" : a bare IP or prefix-CIDR, ready to emit.
//   - host != ""                  : an RFC-1123 hostname (+ optional port) that
//     the caller must resolve to IP literals.
//
// A grammar violation (out-of-range/non-numeric port, netmask-form CIDR, a
// non-hostname host operand) is an error — never folded into the host operand
// (the pre-fix parseEgressEntry laundering bug).
func parseEgressGrammar(entry string) (host string, port int, literals []egressDaddr, err error) {
	// Bare IP literal (covers IPv6 with its colons before the port split).
	if ip := net.ParseIP(entry); ip != nil {
		return "", 0, []egressDaddr{{family: ipFamily(ip), addr: ip.String()}}, nil
	}
	// Prefix-form CIDR. netip.ParsePrefix accepts ONLY prefix form (a
	// netmask-form CIDR's "/255.0.0.0" tail is not a valid decimal prefix
	// length), so a netmask-form CIDR fails here as the contract requires —
	// same refusal as the net.ParseCIDR this replaced. egressCanonicalCIDR
	// (see its own doc, item 3 of the IMP-13645c4df90a review round) also
	// rejects an IPv4-mapped IPv6 CIDR outright and renders the CANONICAL
	// masked text rather than the raw entry — rendering the raw entry
	// alongside a family derived from net.IP.To4()'s notion of "v4" (which
	// disagrees with the address's own text form for a mapped CIDR) used to
	// emit a line nft rejects, failing the WHOLE atomic apply every tick.
	// No minimum prefix length is enforced here (unlike splitEgressCIDRs):
	// a module's egress_allow "0.0.0.0/0"/"::/0" wildcard is a deliberately
	// supported, human-reviewed contract entry (see this file's top-of-file
	// doc), not something this path may silently narrow.
	if strings.Contains(entry, "/") {
		prefix, ok, reason := egressCanonicalCIDR(entry)
		if !ok {
			return "", 0, nil, fmt.Errorf("not a prefix-form CIDR: %s", reason)
		}
		family := "ip"
		if prefix.Addr().Is6() {
			family = "ip6"
		}
		return "", 0, []egressDaddr{{family: family, addr: prefix.String()}}, nil
	}
	// hostname:port or IP:port. A colon here can only be a port separator (bare
	// IPv6 was handled above), so split on the LAST colon.
	h := entry
	if idx := strings.LastIndexByte(entry, ':'); idx >= 0 {
		h = entry[:idx]
		p, perr := strconv.Atoi(entry[idx+1:])
		if perr != nil || p < 1 || p > 65535 {
			return "", 0, nil, fmt.Errorf("port %q is not 1-65535", entry[idx+1:])
		}
		port = p
	}
	// IPv4-literal:port — emit as a literal (no DNS), family by the literal.
	if ip := net.ParseIP(h); ip != nil {
		return "", port, []egressDaddr{{family: ipFamily(ip), addr: ip.String()}}, nil
	}
	if !egressHostnamePattern.MatchString(h) {
		return "", 0, nil, fmt.Errorf("host %q is not an RFC-1123 hostname, IP, or CIDR", h)
	}
	return h, port, nil, nil
}

// RemoveEgressAllowlist tears down the egress chain. Called when a module
// is detached.
func RemoveEgressAllowlist(ctx context.Context, runner mount.Runner) error {
	chain := "powernode_egress_filter"
	return runner.Run(ctx, "nft", "delete", "chain", "inet", EgressTable, chain)
}

// resolveProtectedHost normalises a protected-host entry to one or
// more net.IP literals. If `entry` is already an IP literal it returns
// just that IP; otherwise it asks the resolver for A/AAAA records and
// returns every address. Empty result is a hard error — silently
// failing here would leave the agent firewalled off.
func resolveProtectedHost(entry string) ([]net.IP, error) {
	if ip := net.ParseIP(entry); ip != nil {
		return []net.IP{ip}, nil
	}
	addrs, err := net.LookupIP(entry)
	if err != nil {
		return nil, fmt.Errorf("resolve %q: %w", entry, err)
	}
	if len(addrs) == 0 {
		return nil, fmt.Errorf("resolve %q: no A/AAAA records", entry)
	}
	return addrs, nil
}

// egressHostnamePattern is the on-node twin of the contract's HOSTNAME_RX
// (RFC-1123 labels). Applied after the coarse character screen in
// buildEgressRules, so it only has to bound label/segment shape.
var egressHostnamePattern = regexp.MustCompile(`^[A-Za-z0-9]([A-Za-z0-9-]{0,62})?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,62})?)*$`)

// maxEgressEntries mirrors the contract cap (MAX_EGRESS_ENTRIES) so a hostile
// or runaway union cannot emit an unbounded rule set.
const maxEgressEntries = 64

// egressResolveHost resolves a hostname allowlist entry to IP literals. Var so
// tests can inject a deterministic resolver (nft consumes IP literals, not
// hostnames — see the protectedHosts loop's history comment).
var egressResolveHost = net.LookupIP
