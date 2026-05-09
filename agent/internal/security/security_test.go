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
	// At minimum, capsh should run with --drop=all and nft should set up egress
	if !invokedWith(rec, "capsh", "--drop=all") {
		t.Errorf("expected capsh --drop=all; got %+v", rec.Invocations)
	}
	if !invokedWith(rec, "nft", "add") {
		t.Errorf("expected nft add invocation; got %+v", rec.Invocations)
	}
}

func TestPolicy_Apply_AllowedCapsPassedToCapsh(t *testing.T) {
	rec := &mount.RecorderRunner{}
	p := &Policy{Capabilities: []string{"CAP_NET_BIND_SERVICE", "CAP_CHOWN"}}
	if err := p.Apply(context.Background(), rec); err != nil {
		t.Fatalf("Apply: %v", err)
	}
	caps := findCapsArg(rec)
	if !strings.Contains(caps, "net_bind_service") {
		t.Errorf("expected net_bind_service in caps arg, got %q", caps)
	}
	if !strings.Contains(caps, "chown") {
		t.Errorf("expected chown in caps arg, got %q", caps)
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
