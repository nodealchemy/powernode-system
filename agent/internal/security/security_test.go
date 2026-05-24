package security

import (
	"context"
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
	// (covered by TestWriteCapabilityDropIn_* below). Apply should still
	// install egress + MAC rules, so nft must run.
	if !invokedWith(rec, "nft", "add") {
		t.Errorf("expected nft add invocation; got %+v", rec.Invocations)
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
	p := &Policy{Privileged: true, EgressAllow: []string{"api.example.com:443"}}
	if err := p.Apply(context.Background(), rec); err != nil {
		t.Fatalf("Apply: %v", err)
	}
	if invokedWith(rec, "capsh", "--drop=all") {
		t.Errorf("privileged policy should NOT drop capabilities")
	}
	if !invokedWith(rec, "nft", "add") {
		t.Errorf("privileged policy should still install egress rules")
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
	rec := &mount.RecorderRunner{}
	allow := []string{"api.example.com:443", "1.2.3.4"}
	if err := ApplyEgressAllowlist(context.Background(), rec, allow); err != nil {
		t.Fatalf("ApplyEgressAllowlist: %v", err)
	}
	if !rulesAccept(rec, "api.example.com") {
		t.Error("expected api.example.com rule")
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
		context.Background(), rec, nil, []string{"10.125.0.246"},
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
			case "10.125.0.246":
				sawAddr = true
			}
		}
		if sawIp && sawDaddr && sawAddr {
			found = true
			break
		}
	}
	if !found {
		t.Errorf("expected `ip daddr 10.125.0.246 accept` rule for protected host; got: %+v", rec.Invocations)
	}
}

func TestResolveProtectedHost_IPLiteralPassesThrough(t *testing.T) {
	ips, err := resolveProtectedHost("10.125.0.246")
	if err != nil {
		t.Fatalf("resolveProtectedHost: %v", err)
	}
	if len(ips) != 1 || ips[0].String() != "10.125.0.246" {
		t.Errorf("expected single literal 10.125.0.246; got %v", ips)
	}
}

func TestParseEgressEntry(t *testing.T) {
	cases := []struct {
		in       string
		wantHost string
		wantPort int
	}{
		{"api.example.com:443", "api.example.com", 443},
		{"1.2.3.4", "1.2.3.4", 0},
		{"host.example.com", "host.example.com", 0},
		{"badport:99999", "badport:99999", 0}, // out-of-range port → treat whole as host
	}
	for _, c := range cases {
		host, port := parseEgressEntry(c.in)
		if host != c.wantHost || port != c.wantPort {
			t.Errorf("parseEgressEntry(%q) = (%q, %d); want (%q, %d)",
				c.in, host, port, c.wantHost, c.wantPort)
		}
	}
}

func TestResolveProfileInModule(t *testing.T) {
	cases := []struct {
		mod, rel, want string
	}{
		{"/run/powernode/modules/abc", "policy.te", "/run/powernode/modules/abc/policy.te"},
		{"/mod", "./profile.json", "/mod/profile.json"},
		{"/mod", "/abs/profile", "/abs/profile"},
		{"/mod", "", ""},
	}
	for _, c := range cases {
		got := ResolveProfileInModule(c.mod, c.rel)
		if got != c.want {
			t.Errorf("ResolveProfileInModule(%q, %q) = %q; want %q", c.mod, c.rel, got, c.want)
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
