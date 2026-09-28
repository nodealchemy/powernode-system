package security

import (
	"context"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

func TestPolicy_Apply_DropAllByDefault(t *testing.T) {
	rec := &mount.RecorderRunner{}
	p := &Policy{}
	if err := p.Apply(context.Background(), rec); err != nil {
		t.Fatalf("Apply: %v", err)
	}
	// Apply no longer shells out to capsh — capability enforcement moved
	// to per-unit systemd drop-ins written by WriteCapabilityDropIn
	// (covered by TestWriteCapabilityDropIn_* below). Apply also no
	// longer touches egress/nft at all — that's now a node-wide UNION
	// computed once per reconcile tick by UnionEgressPolicy, never by a
	// single module's own Apply (see TestUnionEgressPolicy_* below and
	// Policy.Apply's doc comment for why: a per-module nft chain write
	// let whichever module reconciled last silently clobber every
	// sibling's declared policy).
	if invokedWith(rec, "nft", "add") {
		t.Errorf("did not expect Apply to touch nft directly (egress is unioned node-wide, not per-module); got %+v", rec.Invocations)
	}
	if invokedWith(rec, "capsh", "--drop=all") {
		t.Errorf("did not expect legacy capsh shellout (replaced by systemd drop-in)")
	}
}

func TestPolicy_Apply_AllowedCapsValidatedOnly(t *testing.T) {
	rec := &mount.RecorderRunner{}
	p := &Policy{Capabilities: []string{"CAP_NET_BIND_SERVICE", "CAP_CHOWN"}}
	if err := p.Apply(context.Background(), rec); err != nil {
		t.Fatalf("Apply: %v", err)
	}
	// Apply validates cap names — no capsh side-effect. Per-unit
	// enforcement is exercised by TestWriteCapabilityDropIn_* below.
	for _, inv := range rec.Invocations {
		if inv.Name == "capsh" {
			t.Errorf("did not expect capsh invocation (caps now enforced via systemd drop-ins); got %+v", inv)
		}
	}
}

func TestDropCapabilitiesExcept_RejectsUnknownCap(t *testing.T) {
	rec := &mount.RecorderRunner{}
	err := DropCapabilitiesExcept(context.Background(), rec, []string{"CAP_TOTALLY_FAKE"})
	if err == nil || !strings.Contains(err.Error(), "CAP_TOTALLY_FAKE") {
		t.Errorf("expected error mentioning CAP_TOTALLY_FAKE; got %v", err)
	}
}

// K5b (review round 6): Validate no longer treats an unknown capability
// name as an error — Policy.DropUnknownCapabilities must run first and
// silently (from Validate's perspective) narrows the ceiling instead, so an
// older agent receiving a manifest naming a capability a newer agent
// version added does not refuse the whole module over one name it doesn't
// recognize. This test used to assert the OPPOSITE (RejectsUnknownCap);
// renamed and rewritten to pin the new, deliberate behavior.
func TestPolicy_DropUnknownCapabilities_NarrowsCeilingWithoutFailingValidate(t *testing.T) {
	p := &Policy{Capabilities: []string{"CAP_CHOWN", "CAP_FAKE_NONSENSE"}}
	dropped := p.DropUnknownCapabilities()
	if len(dropped) != 1 || dropped[0] != "CAP_FAKE_NONSENSE" {
		t.Fatalf("expected DropUnknownCapabilities to report [CAP_FAKE_NONSENSE], got %v", dropped)
	}
	if len(p.Capabilities) != 1 || p.Capabilities[0] != "CAP_CHOWN" {
		t.Errorf("expected the unknown name removed IN PLACE, leaving only CAP_CHOWN, got %v", p.Capabilities)
	}
	if errs := p.Validate(); len(errs) != 0 {
		t.Errorf("Validate must not error on a policy already run through DropUnknownCapabilities, got %v", errs)
	}
}

// DropUnknownCapabilities is NARROWER ONLY — it must never widen the
// declared ceiling, and a policy with no unknown names must be untouched
// (nil dropped, same slice contents).
func TestPolicy_DropUnknownCapabilities_NoOpWhenEverythingIsKnown(t *testing.T) {
	p := &Policy{Capabilities: []string{"CAP_CHOWN", "CAP_NET_ADMIN"}}
	dropped := p.DropUnknownCapabilities()
	if dropped != nil {
		t.Errorf("expected nil dropped when every name is known, got %v", dropped)
	}
	if len(p.Capabilities) != 2 {
		t.Errorf("expected both known capabilities preserved, got %v", p.Capabilities)
	}
}

func TestPolicy_Validate_RejectsMixedPrivilegedAndPolicy(t *testing.T) {
	p := &Policy{Privileged: true, Capabilities: []string{"CAP_CHOWN"}}
	errs := p.Validate()
	if len(errs) == 0 {
		t.Fatal("expected error: privileged=true with explicit caps")
	}
}

// TestPolicyValidate_RejectsPrivilegedWithSeccomp pins the coupling
// RenderedPolicyHash's seccomp gating depends on (policy_stamp.go): unlike
// capabilities, attachModule's seccomp write loop (reconcile.go) has no
// `!policy.Privileged` condition of its own — a Privileged module can only
// ever reach that loop with an empty SeccompProfile because Validate refuses
// the combination here, in a different file. If this test is ever the one
// that breaks, RenderedPolicyHash's seccomp component (deliberately gated on
// `SeccompProfile != ""` alone, NOT on `!p.Privileged`) needs the same
// re-examination, not just this assertion updated.
func TestPolicyValidate_RejectsPrivilegedWithSeccomp(t *testing.T) {
	p := &Policy{Privileged: true, SeccompProfile: "default"}
	errs := p.Validate()
	if len(errs) == 0 {
		t.Fatal("expected error: privileged=true with an explicit seccomp_profile")
	}
}

func TestPolicy_Privileged_SkipsMACAndCaps(t *testing.T) {
	rec := &mount.RecorderRunner{}
	p := &Policy{Privileged: true, EgressDeclared: true, EgressAllow: []string{"api.example.com:443"}}
	if err := p.Apply(context.Background(), rec); err != nil {
		t.Fatalf("Apply: %v", err)
	}
	if invokedWith(rec, "capsh", "--drop=all") {
		t.Errorf("privileged policy should NOT drop capabilities")
	}
	// Apply itself never touches nft (privileged or not) — a privileged
	// module's EgressAllow still flows into the node-wide union exactly
	// like any other module's, via UnionEgressPolicy at the reconciler
	// level, not here.
	if invokedWith(rec, "nft", "add") {
		t.Errorf("did not expect Apply to touch nft directly, even for a privileged policy; got %+v", rec.Invocations)
	}
}

func TestUnionEgressPolicy_NoModuleDeclared_NotEnforced(t *testing.T) {
	policies := []*Policy{
		{},                                    // no security block at all
		{Capabilities: []string{"CAP_CHOWN"}}, // has an opinion on caps, none on egress
		nil,
	}
	allow, enforced := UnionEgressPolicy(policies)
	if enforced {
		t.Errorf("expected enforced=false when no policy declares egress_allow; got allow=%v", allow)
	}
	if len(allow) != 0 {
		t.Errorf("expected empty allowlist; got %v", allow)
	}
}

func TestUnionEgressPolicy_UnionsAcrossModules_PermissiveSurvives(t *testing.T) {
	// Regression for the exact dev-cell + claude-tmux bug: one module
	// declares an explicit empty (restrictive) allowlist, a sibling
	// declares an unrestricted wildcard. Order must not matter — the
	// wildcard must survive regardless of which policy is unioned first.
	restrictive := &Policy{EgressDeclared: true, EgressAllow: nil}
	permissive := &Policy{EgressDeclared: true, EgressAllow: []string{"0.0.0.0/0"}}

	allowA, enforcedA := UnionEgressPolicy([]*Policy{restrictive, permissive})
	allowB, enforcedB := UnionEgressPolicy([]*Policy{permissive, restrictive})

	for _, tc := range []struct {
		name     string
		allow    []string
		enforced bool
	}{
		{"restrictive-then-permissive", allowA, enforcedA},
		{"permissive-then-restrictive", allowB, enforcedB},
	} {
		if !tc.enforced {
			t.Errorf("%s: expected enforced=true", tc.name)
		}
		if len(tc.allow) != 1 || tc.allow[0] != "0.0.0.0/0" {
			t.Errorf("%s: expected union to contain the wildcard regardless of order; got %v", tc.name, tc.allow)
		}
	}
}

func TestUnionEgressPolicy_DedupesOverlappingEntries(t *testing.T) {
	a := &Policy{EgressDeclared: true, EgressAllow: []string{"api.example.com:443", "shared.example.com"}}
	b := &Policy{EgressDeclared: true, EgressAllow: []string{"shared.example.com", "other.example.com:22"}}
	allow, enforced := UnionEgressPolicy([]*Policy{a, b})
	if !enforced {
		t.Fatal("expected enforced=true")
	}
	counts := map[string]int{}
	for _, e := range allow {
		counts[e]++
	}
	if counts["shared.example.com"] != 1 {
		t.Errorf("expected shared.example.com exactly once; got counts=%v allow=%v", counts, allow)
	}
	for _, want := range []string{"api.example.com:443", "shared.example.com", "other.example.com:22"} {
		if counts[want] != 1 {
			t.Errorf("expected %q present exactly once; got %v", want, allow)
		}
	}
}

func TestUnionEgressPolicy_UndeclaredModuleContributesNothing(t *testing.T) {
	// A module with no security block at all must not force node-wide
	// enforcement just by being attached alongside modules that do.
	noOpinion := &Policy{}
	permissive := &Policy{EgressDeclared: true, EgressAllow: []string{"0.0.0.0/0"}}
	allow, enforced := UnionEgressPolicy([]*Policy{noOpinion, permissive})
	if !enforced || len(allow) != 1 || allow[0] != "0.0.0.0/0" {
		t.Errorf("expected only the declaring module's entries; got allow=%v enforced=%v", allow, enforced)
	}
}

func TestApplyEgressAllowlist_AllowsLoopbackAndDNS(t *testing.T) {
	rec := &mount.RecorderRunner{}
	withTempEgressScriptPath(t)
	if err := ApplyEgressAllowlist(context.Background(), rec, []string{}); err != nil {
		t.Fatalf("ApplyEgressAllowlist: %v", err)
	}
	assertSingleNftDashF(t, rec)
	script := readEgressScript(t)
	if !rulesAccept(script, "lo") {
		t.Error("expected loopback accept rule")
	}
	if !rulesAccept(script, "53") {
		t.Error("expected DNS port 53 accept rule")
	}
}

func TestApplyEgressAllowlist_PerEntryRules(t *testing.T) {
	// nft consumes IP literals, not hostnames, so a hostname entry is resolved
	// in Go first. Inject a deterministic resolver so the test never touches DNS.
	orig := egressResolveHost
	egressResolveHost = func(h string) ([]net.IP, error) {
		if h == "api.example.com" {
			return []net.IP{net.ParseIP("203.0.113.7")}, nil
		}
		return nil, fmt.Errorf("unexpected host %q", h)
	}
	t.Cleanup(func() { egressResolveHost = orig })

	rec := &mount.RecorderRunner{}
	withTempEgressScriptPath(t)
	allow := []string{"api.example.com:443", "1.2.3.4"}
	if err := ApplyEgressAllowlist(context.Background(), rec, allow); err != nil {
		t.Fatalf("ApplyEgressAllowlist: %v", err)
	}
	script := readEgressScript(t)
	if !rulesAccept(script, "203.0.113.7") {
		t.Error("expected resolved api.example.com (203.0.113.7) rule")
	}
	if !rulesAccept(script, "443") {
		t.Error("expected port 443 rule")
	}
	if !rulesAccept(script, "1.2.3.4") {
		t.Error("expected 1.2.3.4 rule")
	}
}

// Protected hosts are the agent's escape hatch from its own egress
// policy (typically the platform URL). They MUST land in the chain
// as IP literals — passing `ip daddr <hostname>` to nft has been
// observed to silently fail at install on cloud-VM dogfood runs,
// leaving the agent firewalled off from its parent. Verify that an
// IP-literal protected host appears as an `ip daddr <ip> accept`
// rule.
func TestApplyEgressAllowlist_ProtectedHostIPLiteral(t *testing.T) {
	rec := &mount.RecorderRunner{}
	withTempEgressScriptPath(t)
	if err := ApplyEgressAllowlistWithProtected(
		context.Background(), rec, nil, []string{"192.0.2.10"},
	); err != nil {
		t.Fatalf("ApplyEgressAllowlistWithProtected: %v", err)
	}
	script := readEgressScript(t)
	if !hasRule(script, "ip", "daddr", "192.0.2.10", "accept") {
		t.Errorf("expected `ip daddr 192.0.2.10 accept` rule for protected host; got script:\n%s", script)
	}
}

// IMP-13645c4df90a review round item 2 (per-process staging filename): the
// staged script is removed after apply in production. Every other test in
// this package relies on testing.Testing()'s exemption to read the file
// back; this one flips SetEgressForceCleanupForTest to observe the removal
// itself.
func TestApplyEgressAllowlist_RemovesStagedScriptAfterApply(t *testing.T) {
	rec := &mount.RecorderRunner{}
	withTempEgressScriptPath(t)
	t.Cleanup(SetEgressForceCleanupForTest(true))
	if err := ApplyEgressAllowlist(context.Background(), rec, nil); err != nil {
		t.Fatalf("ApplyEgressAllowlist: %v", err)
	}
	if _, err := os.Stat(egressStagingPath()); !os.IsNotExist(err) {
		t.Errorf("expected the staged script to be removed after apply, stat err=%v", err)
	}
}

func TestResolveProtectedHost_IPLiteralPassesThrough(t *testing.T) {
	ips, err := resolveProtectedHost("192.0.2.10")
	if err != nil {
		t.Fatalf("resolveProtectedHost: %v", err)
	}
	if len(ips) != 1 || ips[0].String() != "192.0.2.10" {
		t.Errorf("expected single literal 192.0.2.10; got %v", ips)
	}
}

// parseEgressGrammar is the DNS-free grammar parse (replaces classifyEgressEntry
// + parseEgressEntry). IP/CIDR entries come back as literals with host=="";
// hostnames come back as host!="" for the caller to resolve. The load-bearing
// change is that an out-of-range/non-numeric port, a netmask CIDR, or a zone-id
// is an ERROR, never folded back into the host operand.
func TestParseEgressGrammar(t *testing.T) {
	litCases := []struct {
		in     string
		family string
		addr   string
		port   int
	}{
		{"1.2.3.4", "ip", "1.2.3.4", 0},
		{"1.2.3.4:443", "ip", "1.2.3.4", 443}, // NOTE: port applies but literal is bare IP
		{"0.0.0.0/0", "ip", "0.0.0.0/0", 0},
		{"::/0", "ip6", "::/0", 0},
		{"2001:db8::1", "ip6", "2001:db8::1", 0},
	}
	for _, c := range litCases {
		host, port, literals, err := parseEgressGrammar(c.in)
		if err != nil {
			t.Errorf("parseEgressGrammar(%q) errored: %v", c.in, err)
			continue
		}
		if host != "" {
			t.Errorf("parseEgressGrammar(%q) returned host=%q; want a literal", c.in, host)
			continue
		}
		if len(literals) != 1 || literals[0].family != c.family || literals[0].addr != c.addr || port != c.port {
			t.Errorf("parseEgressGrammar(%q) = %+v port=%d; want {%s %s} port=%d", c.in, literals, port, c.family, c.addr, c.port)
		}
	}
	// A hostname parses (no DNS here) and comes back for the caller to resolve.
	if host, port, lits, err := parseEgressGrammar("api.example.com:443"); err != nil || host != "api.example.com" || port != 443 || lits != nil {
		t.Errorf(`parseEgressGrammar("api.example.com:443") = (%q,%d,%v,%v); want ("api.example.com",443,nil,nil)`, host, port, lits, err)
	}
	for _, bad := range []string{
		"badport:99999", "host.example.com:abc", "10.0.0.0/255.0.0.0", "fe80::1%eth0",
		"::ffff:0:0/96", // IMP-13645c4df90a review round item 3: IPv4-mapped IPv6 CIDR, refused outright
	} {
		if _, _, _, err := parseEgressGrammar(bad); err == nil {
			t.Errorf("parseEgressGrammar(%q) accepted a contract-invalid entry", bad)
		}
	}
}

// IMP-13645c4df90a review round item 3: an entry with non-zero host bits
// ("10.0.0.5/24" — a legal, if unusual, prefix-form CIDR) used to render the
// RAW entry text; a caller writing an address that doesn't sit on the
// prefix boundary would get exactly that address back, not the network it
// names. The canonical (Masked) form is what egressCanonicalCIDR now emits,
// matching the SDWAN AllowedIPs path (splitEgressCIDRs) — one canonicalizer
// for both.
func TestParseEgressGrammar_CanonicalizesNonZeroHostBits(t *testing.T) {
	_, _, literals, err := parseEgressGrammar("10.0.0.5/24")
	if err != nil {
		t.Fatalf("parseEgressGrammar(%q) errored: %v", "10.0.0.5/24", err)
	}
	if len(literals) != 1 || literals[0].family != "ip" || literals[0].addr != "10.0.0.0/24" {
		t.Errorf(`parseEgressGrammar("10.0.0.5/24") = %+v; want a single ip literal "10.0.0.0/24" (masked)`, literals)
	}
}

// IMP-13645c4df90a review round item 6: the grammar guard is STRUCTURAL, not
// merely "every line passes a charset". A line that is charset-clean but
// does not target the exact table/chain this package renders into (or a
// header line that has been subtly rewritten) must be refused even though a
// naive charset-only check would have accepted it.
func TestValidateEgressScriptGrammar_StructuralChecks(t *testing.T) {
	goodHeader := strings.Join(egressScriptHeaderLines, "\n") + "\n"

	t.Run("accepts a well-formed script", func(t *testing.T) {
		script := goodHeader + egressScriptRulePrefix + "ct state established,related accept\n"
		if err := validateEgressScriptGrammar(script); err != nil {
			t.Errorf("expected a well-formed script to pass, got: %v", err)
		}
	})

	t.Run("rejects a rule line targeting a DIFFERENT table (charset-clean, wrong prefix)", func(t *testing.T) {
		script := goodHeader + "add rule inet some_other_table powernode_egress_filter ip daddr 1.2.3.4 accept\n"
		if err := validateEgressScriptGrammar(script); err == nil {
			t.Error("expected a rule line targeting a different table to be refused")
		}
	})

	t.Run("rejects a rule line targeting a DIFFERENT chain (charset-clean, wrong prefix)", func(t *testing.T) {
		script := goodHeader + "add rule inet " + EgressTable + " some_other_chain ip daddr 1.2.3.4 accept\n"
		if err := validateEgressScriptGrammar(script); err == nil {
			t.Error("expected a rule line targeting a different chain to be refused")
		}
	})

	t.Run("rejects a subtly rewritten chain-definition header (still charset-clean)", func(t *testing.T) {
		lines := append([]string(nil), egressScriptHeaderLines...)
		lines[1] = strings.Replace(lines[1], "policy drop", "policy accept", 1)
		script := strings.Join(lines, "\n") + "\n" + egressScriptRulePrefix + "ct state established,related accept\n"
		if err := validateEgressScriptGrammar(script); err == nil {
			t.Error("expected a rewritten (policy accept instead of drop) chain header to be refused")
		}
	})

	t.Run("rejects the header lines out of order", func(t *testing.T) {
		lines := []string{egressScriptHeaderLines[1], egressScriptHeaderLines[0], egressScriptHeaderLines[2]}
		script := strings.Join(lines, "\n") + "\n"
		if err := validateEgressScriptGrammar(script); err == nil {
			t.Error("expected out-of-order header lines to be refused")
		}
	})

	t.Run("still refuses a semicolon on a rule line, unlike the exempted chain header", func(t *testing.T) {
		script := goodHeader + egressScriptRulePrefix + "ct state established,related accept ; add rule\n"
		if err := validateEgressScriptGrammar(script); err == nil {
			t.Error("expected a semicolon on a rule line to be refused")
		}
	})
}

func TestKnownCapabilities_HasReasonableSet(t *testing.T) {
	for _, must := range []string{"CAP_CHOWN", "CAP_NET_BIND_SERVICE", "CAP_SYS_ADMIN", "CAP_DAC_OVERRIDE"} {
		if _, ok := KnownCapabilities[must]; !ok {
			t.Errorf("expected %s in KnownCapabilities", must)
		}
	}
}

// ---------- helpers ----------

func invokedWith(r *mount.RecorderRunner, name string, argSubstr string) bool {
	for _, inv := range r.Invocations {
		if inv.Name != name {
			continue
		}
		for _, a := range inv.Args {
			if strings.Contains(a, argSubstr) {
				return true
			}
		}
	}
	return false
}

// findCapsArg is retained for any out-of-tree callers that historically
// inspected the legacy capsh args. The agent no longer invokes capsh,
// so this helper will always return "" in current builds. Kept to avoid
// breaking imports; remove on the next major test refactor.
func findCapsArg(r *mount.RecorderRunner) string {
	for _, inv := range r.Invocations {
		if inv.Name != "capsh" {
			continue
		}
		for _, a := range inv.Args {
			if strings.HasPrefix(a, "--caps=") {
				return a
			}
		}
	}
	return ""
}

// rulesAccept returns true when any LINE of a rendered egress script (see
// readEgressScript) contains `match` and ends with "accept". Egress apply is
// now one `nft -f <script>` transaction (IMP-13645c4df90a atomic rebuild),
// so there is no longer a per-rule nft invocation to inspect — assertions
// read the script file the apply staged instead. Kept substring-based
// (rather than an exact-line hasRule match) for callers that only care
// whether SOME rule mentions a value, not its exact surrounding tokens.
func rulesAccept(script, match string) bool {
	for _, line := range strings.Split(script, "\n") {
		if strings.Contains(line, match) && strings.HasSuffix(line, "accept") {
			return true
		}
	}
	return false
}

// hasRule reports whether the rendered egress script contains a rule line
// whose trailing tokens (after "add rule inet <table> <chain> ") exactly
// match want, joined by single spaces, in order.
func hasRule(script string, want ...string) bool {
	target := fmt.Sprintf("add rule inet %s %s %s", EgressTable, egressChain, strings.Join(want, " "))
	for _, line := range strings.Split(script, "\n") {
		if line == target {
			return true
		}
	}
	return false
}

// withTempEgressScriptPath redirects the package-level egressScriptPath
// into a per-test temp dir for the test's duration, restoring the original
// after. Every test that calls an ApplyEgress* function and then wants to
// inspect what was rendered needs this — production defaults to the
// root-only /run/powernode-agent/egress.nft, which a test must never touch.
// Thin wrapper over SetEgressScriptPathForTest (the same seam runtime's
// reconcile_test.go uses cross-package) so there is one mechanism, not two.
func withTempEgressScriptPath(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "egress.nft")
	restore := SetEgressScriptPathForTest(path)
	t.Cleanup(restore)
	return path
}

// readEgressScript reads back the script the most recent ApplyEgress* call
// staged at egressScriptPath. Callers must have called
// withTempEgressScriptPath first (real production code path — the write is
// genuine fsutil.AtomicWrite I/O, never faked by RecorderRunner, which only
// records the trailing `nft -f <path>` invocation).
func readEgressScript(t *testing.T) string {
	t.Helper()
	path := egressStagingPath()
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read egress script %s: %v", path, err)
	}
	return string(body)
}

// assertEgressScriptGrammar re-runs the SAME production fail-closed guard
// (validateEgressScriptGrammar) a rendered script already passed inside
// renderEgressScript, directly against test-obtained script text — the plan
// calls for the grammar guard to be "reused by tests", not re-implemented
// with a second, potentially-diverging character class.
func assertEgressScriptGrammar(t *testing.T, script string) {
	t.Helper()
	if err := validateEgressScriptGrammar(script); err != nil {
		t.Fatalf("rendered egress script failed its own grammar guard: %v\nscript:\n%s", err, script)
	}
}

// assertSingleNftDashF pins the atomic-rebuild invariant every successful
// apply must hold: exactly one nft invocation, and it is `-f <path>` — never
// a per-rule call, and never `delete chain`.
func assertSingleNftDashF(t *testing.T, r *mount.RecorderRunner) {
	t.Helper()
	var nftCalls []mount.Invocation
	for _, inv := range r.Invocations {
		if inv.Name == "nft" {
			nftCalls = append(nftCalls, inv)
		}
	}
	if len(nftCalls) != 1 {
		t.Fatalf("expected exactly one nft invocation, got %d: %+v", len(nftCalls), nftCalls)
	}
	if len(nftCalls[0].Args) < 1 || nftCalls[0].Args[0] != "-f" {
		t.Fatalf("expected the one nft invocation to be `-f <path>`, got %v", nftCalls[0].Args)
	}
	for _, a := range nftCalls[0].Args {
		if a == "delete" {
			t.Fatalf("must never `delete chain` — atomic rebuild uses flush, not delete-then-add: %v", nftCalls[0].Args)
		}
	}
}

// F3 — Policy.Validate must reject a path-bearing or control-char SELinux/
// AppArmor profile NAME. On the pivot/compose path Validate is the ONLY MAC
// check (that path never calls the loaders), so this is load-bearing there,
// not defense-in-depth. Pins the profileNamePattern check inside Validate.
func TestPolicyValidate_RejectsMACProfilePaths(t *testing.T) {
	for _, bad := range []string{"../etc/evil", "sub/prof", "./x", "a\nb", "/abs/path"} {
		if errs := (&Policy{SELinuxProfile: bad, UserNamespace: true}).Validate(); len(errs) == 0 {
			t.Errorf("Validate accepted selinux_profile %q (must be a bare agent-owned name)", bad)
		}
		if errs := (&Policy{AppArmorProfile: bad, UserNamespace: true}).Validate(); len(errs) == 0 {
			t.Errorf("Validate accepted apparmor_profile %q (must be a bare agent-owned name)", bad)
		}
	}
	// A bare name validates clean (over-rejection guard).
	if errs := (&Policy{SELinuxProfile: "my-policy", AppArmorProfile: "app.profile", UserNamespace: true}).Validate(); len(errs) != 0 {
		t.Errorf("Validate rejected legitimate bare MAC names: %v", errs)
	}
}
