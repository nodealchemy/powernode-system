package security

import (
	"context"
	"fmt"
	"net"
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

func TestPolicy_Validate_RejectsUnknownCap(t *testing.T) {
	p := &Policy{Capabilities: []string{"CAP_CHOWN", "CAP_FAKE_NONSENSE"}}
	errs := p.Validate()
	if len(errs) == 0 {
		t.Fatal("expected validation error for unknown cap")
	}
	found := false
	for _, e := range errs {
		if strings.Contains(e.Error(), "CAP_FAKE_NONSENSE") {
			found = true
		}
	}
	if !found {
		t.Errorf("expected error about CAP_FAKE_NONSENSE; got %v", errs)
	}
}

func TestPolicy_Validate_RejectsMixedPrivilegedAndPolicy(t *testing.T) {
	p := &Policy{Privileged: true, Capabilities: []string{"CAP_CHOWN"}}
	errs := p.Validate()
	if len(errs) == 0 {
		t.Fatal("expected error: privileged=true with explicit caps")
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
	if err := ApplyEgressAllowlist(context.Background(), rec, []string{}); err != nil {
		t.Fatalf("ApplyEgressAllowlist: %v", err)
	}
	if !rulesAccept(rec, "lo") {
		t.Error("expected loopback accept rule")
	}
	if !rulesAccept(rec, "53") {
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
	allow := []string{"api.example.com:443", "1.2.3.4"}
	if err := ApplyEgressAllowlist(context.Background(), rec, allow); err != nil {
		t.Fatalf("ApplyEgressAllowlist: %v", err)
	}
	if !rulesAccept(rec, "203.0.113.7") {
		t.Error("expected resolved api.example.com (203.0.113.7) rule")
	}
	if !rulesAccept(rec, "443") {
		t.Error("expected port 443 rule")
	}
	if !rulesAccept(rec, "1.2.3.4") {
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
	if err := ApplyEgressAllowlistWithProtected(
		context.Background(), rec, nil, []string{"192.0.2.10"},
	); err != nil {
		t.Fatalf("ApplyEgressAllowlistWithProtected: %v", err)
	}
	var found bool
	for _, inv := range rec.Invocations {
		if inv.Op != "Run" || inv.Name != "nft" {
			continue
		}
		var sawIp, sawDaddr, sawAddr bool
		for _, a := range inv.Args {
			switch a {
			case "ip":
				sawIp = true
			case "daddr":
				sawDaddr = true
			case "192.0.2.10":
				sawAddr = true
			}
		}
		if sawIp && sawDaddr && sawAddr {
			found = true
			break
		}
	}
	if !found {
		t.Errorf("expected `ip daddr 192.0.2.10 accept` rule for protected host; got: %+v", rec.Invocations)
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
	for _, bad := range []string{"badport:99999", "host.example.com:abc", "10.0.0.0/255.0.0.0", "fe80::1%eth0"} {
		if _, _, _, err := parseEgressGrammar(bad); err == nil {
			t.Errorf("parseEgressGrammar(%q) accepted a contract-invalid entry", bad)
		}
	}
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

// rulesAccept returns true when any nft invocation includes a rule
// whose args contain `match` and end with "accept".
func rulesAccept(r *mount.RecorderRunner, match string) bool {
	for _, inv := range r.Invocations {
		if inv.Name != "nft" {
			continue
		}
		joined := strings.Join(inv.Args, " ")
		if strings.Contains(joined, match) && strings.Contains(joined, "accept") {
			return true
		}
	}
	return false
}
