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

// nftArgvIsSingleToken asserts no recorded nft argv element could smuggle
// a second command through nft's argv-joining: no whitespace, newline,
// '#', quote or brace in any element, and ';' only as the standalone
// separator token the static chain-create command legitimately uses.
func nftArgvIsSingleToken(t *testing.T, rec *mount.RecorderRunner) {
	t.Helper()
	for _, inv := range rec.Invocations {
		if inv.Name != "nft" {
			continue
		}
		for _, a := range inv.Args {
			if a == ";" || a == "{" || a == "}" {
				continue // static chain-definition tokens emitted by the agent itself
			}
			if strings.ContainsAny(a, " \t\n\r;#\"'{}") {
				t.Fatalf("nft argv element %q (in %v) contains command-splitting characters", a, inv.Args)
			}
		}
	}
}

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
	err := ApplyEgressAllowlistWithProtected(context.Background(), rec, payloads, nil)
	nftArgvIsSingleToken(t, rec)
	// Every payload violates the contract grammar; the refusal must be
	// LOUD (an error the reconciler surfaces), while default-deny stands.
	if err == nil {
		t.Fatalf("all-refused allowlist returned nil error — refusals must be loud")
	}
	// None of the raw payloads may appear as (or inside) any argv element.
	for _, inv := range rec.Invocations {
		if inv.Name != "nft" {
			continue
		}
		for _, a := range inv.Args {
			for _, p := range payloads {
				if strings.Contains(a, p) {
					t.Fatalf("raw payload %q reached nft argv: %v", p, inv.Args)
				}
			}
		}
	}
}

// The port-fold defect specifically: pre-fix, parseEgressEntry returned
// the WHOLE "host:port" text as the host operand when the port half did
// not parse — laundering arbitrary text into `ip daddr <text>`.
func TestApplyEgress_UnparseablePortIsRefusedNotFolded(t *testing.T) {
	rec := &mount.RecorderRunner{}
	err := ApplyEgressAllowlistWithProtected(context.Background(), rec, []string{"badport:99999"}, nil)
	if err == nil {
		t.Fatal("out-of-range port accepted; must be refused, not folded into the host")
	}
	for _, inv := range rec.Invocations {
		for _, a := range inv.Args {
			if strings.Contains(a, "badport") {
				t.Fatalf("folded host operand reached nft argv: %v", inv.Args)
			}
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
	err2 := ApplyEgressAllowlistWithProtected(context.Background(), rec2,
		[]string{"good.example.com", "down.example.com"}, nil)
	if err2 == nil || !strings.Contains(err2.Error(), "down.example.com") {
		t.Fatalf("DNS-failed hostname should be reported as skipped; got %v", err2)
	}
	if !rulesAccept(rec2, "203.0.113.9") {
		t.Error("resolvable hostname should still be applied despite a sibling DNS failure")
	}
	// The unresolved host's name must never reach an nft argv.
	for _, inv := range rec2.Invocations {
		for _, a := range inv.Args {
			if strings.Contains(a, "down.example.com") {
				t.Fatalf("unresolved hostname leaked into nft argv: %v", inv.Args)
			}
		}
	}
}
