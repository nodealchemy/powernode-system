package security

import (
	"context"
	"fmt"
	"net"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// G2 offer 01a02f70-d372 — egress_allow entries become nft operands, and
// nft(8) re-joins its command arguments into one buffer and re-parses it,
// so an argv ELEMENT containing ';', whitespace or a newline yields
// additional nft commands executed as root against the NODE-WIDE chain.
//
// The contract grammar (module_config_validator.rb SECURITY-BLOCK):
// hostname | hostname:port | IP | prefix-form CIDR; no '%' zone-ids, no
// netmask-form CIDR, no whitespace/quotes/semicolons/braces. The agent
// must contain hostile entries independently of the server.
//
// SAFETY: RecorderRunner only — nothing executes, no live nft, no node.
//
// ATOMIC REBUILD (IMP-13645c4df90a, operator-scoped rework): egress apply is
// now one `nft -f <script>` call (renderEgressScript + applyEgressScript),
// which changes WHERE the injection defense lives. Previously, safety came
// from passing each rule as SEPARATE argv elements straight to exec — no
// element could smuggle a second command because exec never re-joins argv
// into a shell string. That defense is gone by construction now: every rule
// is one line of a single text file nft re-parses exactly like it used to
// re-parse joined argv. The defense that replaces it is upstream of
// rendering entirely — buildEgressRules/buildEgressExtrasRules already
// refuse (or skip) any entry containing a disallowed character BEFORE a
// rule token is ever produced — plus validateEgressScriptGrammar as a
// whole-script fail-closed backstop. These tests now assert against the
// rendered SCRIPT TEXT (or its total absence, for a grammar-fatal case)
// rather than per-invocation argv.

func TestApplyEgress_InjectionPayloadsNeverReachArgv(t *testing.T) {
	payloads := []string{
		"1.1.1.1 accept; flush ruleset #",                    // classic second-command payload
		"evil.example.com;flush ruleset",                     // semicolon splice
		"1.2.3.4\ndelete table inet powernode_module_egress", // newline splice
		"10.0.0.1 }",           // brace escape
		"badport:99999",        // out-of-range port must NOT fold into the host operand
		"host.example.com:abc", // non-numeric port must NOT fold into the host operand
		"fe80::1%eth0",         // zone-id — contract-refused spelling
		"10.0.0.0/255.0.0.0",   // netmask-form CIDR — contract-refused spelling
	}
	rec := &mount.RecorderRunner{}
	withTempEgressScriptPath(t)
	err := ApplyEgressAllowlistWithProtected(context.Background(), rec, payloads, nil)
	// Every payload violates the contract grammar; the refusal must be
	// LOUD (an error the reconciler surfaces), while default-deny stands.
	if err == nil {
		t.Fatalf("all-refused allowlist returned nil error — refusals must be loud")
	}
	// A grammar-fatal allowlist means renderEgressScript never even produces
	// a script — so applyEgressScript, and therefore nft, must NEVER be
	// invoked at all. This is a STRONGER guarantee than "the payload didn't
	// reach argv": no chain mutation of any kind was attempted.
	for _, inv := range rec.Invocations {
		if inv.Name == "nft" {
			t.Fatalf("a grammar-fatal allowlist must never reach nft; got %+v", inv.Args)
		}
	}
}

// The port-fold defect specifically: pre-fix, parseEgressEntry returned
// the WHOLE "host:port" text as the host operand when the port half did
// not parse — laundering arbitrary text into `ip daddr <text>`.
func TestApplyEgress_UnparseablePortIsRefusedNotFolded(t *testing.T) {
	rec := &mount.RecorderRunner{}
	withTempEgressScriptPath(t)
	err := ApplyEgressAllowlistWithProtected(context.Background(), rec, []string{"badport:99999"}, nil)
	if err == nil {
		t.Fatal("out-of-range port accepted; must be refused, not folded into the host")
	}
	for _, inv := range rec.Invocations {
		if inv.Name == "nft" {
			t.Fatalf("a grammar-fatal allowlist must never reach nft; got %+v", inv.Args)
		}
	}
}

// F6 — grammar violations abort the whole apply (injection defense) BEFORE any
// nft mutation; a valid hostname that fails DNS is SKIPPED (not fatal) so one
// module's flaky endpoint cannot freeze egress convergence for the node.
func TestApplyEgress_GrammarAbortsVsDNSResolveSkips(t *testing.T) {
	orig := egressResolveHost
	egressResolveHost = func(h string) ([]net.IP, error) {
		switch h {
		case "good.example.com":
			return []net.IP{net.ParseIP("203.0.113.9")}, nil
		default:
			return nil, fmt.Errorf("NXDOMAIN %s", h)
		}
	}
	t.Cleanup(func() { egressResolveHost = orig })

	// A) A grammar-invalid entry aborts before ANY nft call (prior chain intact).
	rec := &mount.RecorderRunner{}
	withTempEgressScriptPath(t)
	err := ApplyEgressAllowlistWithProtected(context.Background(), rec,
		[]string{"good.example.com", "10.0.0.0/255.0.0.0"}, nil)
	if err == nil {
		t.Fatal("grammar-invalid entry must abort the apply")
	}
	for _, inv := range rec.Invocations {
		if inv.Name == "nft" {
			t.Fatalf("grammar abort must precede any nft mutation; saw %v", inv.Args)
		}
	}

	// B) A valid hostname that fails DNS is skipped; the resolvable subset +
	// base chain are applied, and the returned error names the skip (loud, non-
	// destructive).
	rec2 := &mount.RecorderRunner{}
	withTempEgressScriptPath(t)
	err2 := ApplyEgressAllowlistWithProtected(context.Background(), rec2,
		[]string{"good.example.com", "down.example.com"}, nil)
	if err2 == nil || !strings.Contains(err2.Error(), "down.example.com") {
		t.Fatalf("DNS-failed hostname should be reported as skipped; got %v", err2)
	}
	script2 := readEgressScript(t)
	if !rulesAccept(script2, "203.0.113.9") {
		t.Error("resolvable hostname should still be applied despite a sibling DNS failure")
	}
	// The unresolved host's name must never reach the rendered script.
	if strings.Contains(script2, "down.example.com") {
		t.Fatalf("unresolved hostname leaked into the rendered script:\n%s", script2)
	}
}

// The protected-host lockout bug the atomic rebuild fixes: a resolve
// failure on ANY protected host must abort BEFORE any nft mutation — the
// pre-fix code returned mid-build, after the table/chain/static rules were
// already installed via separate nft calls, leaving a drop chain with the
// agent's own control-plane traffic unreachable until the next successful
// tick. Under the atomic rebuild this is now structural (renderEgressScript
// never touches the runner), not merely a lucky call order — pin it directly.
func TestApplyEgress_ProtectedHostResolveFailureAbortsBeforeAnyNftCall(t *testing.T) {
	orig := egressResolveHost
	egressResolveHost = func(h string) ([]net.IP, error) {
		return nil, fmt.Errorf("NXDOMAIN %s", h)
	}
	t.Cleanup(func() { egressResolveHost = orig })

	rec := &mount.RecorderRunner{}
	withTempEgressScriptPath(t)
	err := ApplyEgressAllowlistWithProtected(context.Background(), rec, nil, []string{"platform.example.com"})
	if err == nil {
		t.Fatal("a protected host that will not resolve must abort the apply")
	}
	for _, inv := range rec.Invocations {
		if inv.Name == "nft" {
			t.Fatalf("protected-host resolve failure must precede any nft mutation (the pre-fix lockout bug); saw %v", inv.Args)
		}
	}
}
