package security

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// IMP-13645c4df90a — the node-wide default-deny egress chain was dropping the
// WireGuard handshake outright (verified live on VMs 9005/9007: 296B sent,
// 0B received). EgressExtras/EgressNetwork is the seam
// sdwan.Manager.EgressContributions feeds; these tests drive
// ApplyEgressAllowlistWithExtras directly, the same mount.RecorderRunner +
// egressResolveHost-override pattern as egress_injection_test.go. SAFETY:
// RecorderRunner only — no live nft.
//
// Review-round redesign: a `udp sport <ListenPort> accept` rule (not a
// per-peer daddr:port rule — a hub has no fixed endpoint to reach a NATed
// spoke once conntrack expires, and a daddr:port rule would let any local
// process send UDP to a platform-controlled, SDWAN-write-writable IP:port),
// plus an `oifname <iface> {ip|ip6} daddr { AllowedIPs } accept` scoped to
// what wg_applier.go actually routes onto that interface — never a blanket
// oifname accept, which a pushed 0.0.0.0/0 or ::/0 AllowedIPs would turn
// into unrestricted module egress.
//
// ATOMIC REBUILD (operator-scoped rework of IMP-13645c4df90a): apply is now
// one `nft -f <script>` call, so these assertions read the rendered SCRIPT
// FILE (readEgressScript, after withTempEgressScriptPath) instead of
// per-rule RecorderRunner invocations — see security_test.go's helpers. The
// interface name in a tunnel-scope rule is double-quoted in the rendered
// script (tunnelScopeRule's own doc), so expectations below use `"iface"`.

func TestApplyEgressExtras_SportAndScopedDaddrSetEmitted(t *testing.T) {
	rec := &mount.RecorderRunner{}
	withTempEgressScriptPath(t)
	extras := EgressExtras{Networks: []EgressNetwork{{
		Interface:  "wg-sdwan-a1b2c3",
		ListenPort: 51820,
		AllowedIPs: []string{"fd00:1::5/128", "10.10.0.0/16"},
	}}}
	if err := ApplyEgressAllowlistWithExtras(context.Background(), rec, nil, nil, extras); err != nil {
		t.Fatalf("ApplyEgressAllowlistWithExtras: %v", err)
	}
	script := readEgressScript(t)
	if !hasRule(script, "udp", "sport", "51820", "accept") {
		t.Errorf("missing udp sport accept rule for the network's listen port; script:\n%s", script)
	}
	if !hasRule(script, "oifname", `"wg-sdwan-a1b2c3"`, "ip6", "daddr", "{", "fd00:1::5/128,", "}", "accept") {
		t.Errorf("missing scoped ip6 daddr-set rule; script:\n%s", script)
	}
	if !hasRule(script, "oifname", `"wg-sdwan-a1b2c3"`, "ip", "daddr", "{", "10.10.0.0/16,", "}", "accept") {
		t.Errorf("missing scoped ip daddr-set rule; script:\n%s", script)
	}
	// No oifname clause on the sport rule — the outer WG packet's egress
	// device is the physical route to the peer, never the wg-sdwan-* device.
	for _, line := range strings.Split(script, "\n") {
		if strings.Contains(line, "sport") && strings.Contains(line, "oifname") {
			t.Errorf("the udp sport rule must not carry an oifname clause: %q", line)
		}
	}
}

func TestApplyEgressExtras_UnsetOrInvalidListenPortSkippedNotRendered(t *testing.T) {
	for _, tc := range []struct {
		name string
		port int
	}{
		{"unset", 0},
		{"negative", -1},
		{"too-large", 70000},
	} {
		t.Run(tc.name, func(t *testing.T) {
			rec := &mount.RecorderRunner{}
			withTempEgressScriptPath(t)
			extras := EgressExtras{Networks: []EgressNetwork{{Interface: "wg-sdwan-a1b2c3", ListenPort: tc.port}}}
			err := ApplyEgressAllowlistWithExtras(context.Background(), rec, nil, nil, extras)
			if err == nil {
				t.Fatal("an unset/invalid listen_port must be reported as skipped, not silently dropped")
			}
			script := readEgressScript(t)
			if strings.Contains(script, "sport") {
				t.Fatalf("no sport rule should have been rendered for listen_port=%d:\n%s", tc.port, script)
			}
		})
	}
}

func TestApplyEgressExtras_ZeroCIDRTunnelScopeRejected(t *testing.T) {
	for _, cidr := range []string{"0.0.0.0/0", "::/0", "1.2.3.4/0"} {
		t.Run(cidr, func(t *testing.T) {
			rec := &mount.RecorderRunner{}
			withTempEgressScriptPath(t)
			extras := EgressExtras{Networks: []EgressNetwork{{
				Interface: "wg-sdwan-a1b2c3", ListenPort: 51820, AllowedIPs: []string{cidr},
			}}}
			err := ApplyEgressAllowlistWithExtras(context.Background(), rec, nil, nil, extras)
			if err == nil {
				t.Fatal("a /0 AllowedIPs entry must be refused and reported, not rendered")
			}
			script := readEgressScript(t)
			for _, line := range strings.Split(script, "\n") {
				if strings.Contains(line, "daddr") && strings.Contains(line, "oifname") {
					t.Fatalf("a /0 CIDR must never reach an oifname daddr-set rule: %q", line)
				}
			}
			// The sport rule (unaffected by the AllowedIPs refusal) must still land.
			if !hasRule(script, "udp", "sport", "51820", "accept") {
				t.Error("the sport rule must still apply even when the interface's AllowedIPs are all refused")
			}
		})
	}
}

// IMP-13645c4df90a review round item 1 (HIGH): an IPv4-mapped IPv6 CIDR
// used to slip past the old "ones==0" /0 check (net.ParseCIDR + net.IP.To4
// cannot reliably tell ::ffff:a.b.c.d apart from plain IPv4) and render an
// effectively-unrestricted daddr set. Also covers the classic split-in-half
// evasion of a bare "/0 only" check: 0.0.0.0/1 + 128.0.0.0/1 together cover
// the whole v4 space while each individually clears "not exactly /0" — the
// minimum-prefix-length refusal (v4 /8, v6 /16) blocks both by construction.
func TestApplyEgressExtras_IPv4MappedAndSplitZeroBypassesRejected(t *testing.T) {
	for _, tc := range []struct {
		name string
		ips  []string
	}{
		{"ipv4-mapped-ffff-hex-form", []string{"::ffff:0:0/96"}},
		{"ipv4-mapped-dotted-form", []string{"::ffff:1.2.3.4/96"}},
		{"split-in-half-evades-bare-zero-check", []string{"0.0.0.0/1", "128.0.0.0/1"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			rec := &mount.RecorderRunner{}
			withTempEgressScriptPath(t)
			extras := EgressExtras{Networks: []EgressNetwork{{
				Interface: "wg-sdwan-a1b2c3", ListenPort: 51820, AllowedIPs: tc.ips,
			}}}
			err := ApplyEgressAllowlistWithExtras(context.Background(), rec, nil, nil, extras)
			if err == nil {
				t.Fatal("expected the bypass attempt to be refused and reported, not rendered")
			}
			script := readEgressScript(t)
			for _, line := range strings.Split(script, "\n") {
				if strings.Contains(line, "daddr") && strings.Contains(line, "oifname") {
					t.Fatalf("must never reach an oifname daddr-set rule: %q", line)
				}
			}
			if strings.Contains(script, "0.0.0.0") || strings.Contains(script, "ffff") {
				t.Errorf("no trace of the bypass address text should reach the script:\n%s", script)
			}
			// The sport rule (unaffected by the AllowedIPs refusal) must still land.
			if !hasRule(script, "udp", "sport", "51820", "accept") {
				t.Error("the sport rule must still apply even when the interface's AllowedIPs are all refused")
			}
		})
	}
}

func TestApplyEgressExtras_HostileInterfaceAndCIDRRejected(t *testing.T) {
	rec := &mount.RecorderRunner{}
	withTempEgressScriptPath(t)
	extras := EgressExtras{Networks: []EgressNetwork{
		{Interface: "wg-sdwan-a; flush ruleset #", ListenPort: 51820, AllowedIPs: []string{"10.0.0.0/8"}},
		{Interface: "eth0", ListenPort: 51821, AllowedIPs: []string{"10.0.0.0/8"}},
		{Interface: "wg-sdwan-way-too-long-to-fit-ifnamsiz", ListenPort: 51822, AllowedIPs: []string{"10.0.0.0/8"}},
		{Interface: "wg-sdwan-d4e5f6", ListenPort: 51823, AllowedIPs: []string{"10.0.0.1 accept; flush ruleset #/8", "not-a-cidr"}},
	}}
	err := ApplyEgressAllowlistWithExtras(context.Background(), rec, nil, nil, extras)
	if err == nil {
		t.Fatal("hostile/invalid extras must be reported (loud), not silently swallowed")
	}
	script := readEgressScript(t)
	assertEgressScriptGrammar(t, script)
	// "flush ruleset" (the injected payload) is checked, not bare "flush" —
	// the script's OWN legitimate `flush chain ...` statement (part of the
	// atomic rebuild) contains that substring and must not trip this check.
	for _, bad := range []string{"eth0", "flush ruleset", "way-too-long", "not-a-cidr"} {
		if strings.Contains(script, bad) {
			t.Fatalf("hostile/invalid extras entry reached the rendered script: %q found in:\n%s", bad, script)
		}
	}
	// The one valid network's own sport rule must still land despite three
	// hostile/invalid sibling networks.
	if !hasRule(script, "udp", "sport", "51823", "accept") {
		t.Error("a valid sibling network's sport rule must still apply")
	}
}

func TestApplyEgressExtras_DedupesCIDRsAcrossPeers(t *testing.T) {
	rec := &mount.RecorderRunner{}
	withTempEgressScriptPath(t)
	extras := EgressExtras{Networks: []EgressNetwork{{
		Interface: "wg-sdwan-a1b2c3", ListenPort: 51820,
		// Two peers advertising the SAME CIDR (e.g. a shared aggregate route)
		// plus one distinct spelling that canonicalizes to the same network.
		AllowedIPs: []string{"10.0.0.0/24", "10.0.0.0/24", "10.0.0.5/24"},
	}}}
	if err := ApplyEgressAllowlistWithExtras(context.Background(), rec, nil, nil, extras); err != nil {
		t.Fatalf("ApplyEgressAllowlistWithExtras: %v", err)
	}
	script := readEgressScript(t)
	if !hasRule(script, "oifname", `"wg-sdwan-a1b2c3"`, "ip", "daddr", "{", "10.0.0.0/24,", "}", "accept") {
		t.Errorf("expected a single deduped set element; script:\n%s", script)
	}
}

func TestApplyEgressExtras_SharedListenPortAcrossNetworksEmittedOnce(t *testing.T) {
	// Two networks sharing the SAME node-wide WireGuard listen port must
	// produce exactly one `udp sport <port> accept` line — the kernel socket
	// the rule matches on is bound once per port, not once per network (see
	// buildEgressExtrasRules' seenPorts doc), and a duplicate identical line
	// would be dead weight in every rendered script, not a second
	// independently-meaningful rule.
	rec := &mount.RecorderRunner{}
	withTempEgressScriptPath(t)
	extras := EgressExtras{Networks: []EgressNetwork{
		{Interface: "wg-sdwan-a1b2c3", ListenPort: 51820, AllowedIPs: []string{"10.0.0.0/24"}},
		{Interface: "wg-sdwan-d4e5f6", ListenPort: 51820, AllowedIPs: []string{"10.0.1.0/24"}},
	}}
	if err := ApplyEgressAllowlistWithExtras(context.Background(), rec, nil, nil, extras); err != nil {
		t.Fatalf("ApplyEgressAllowlistWithExtras: %v", err)
	}
	script := readEgressScript(t)
	count := 0
	for _, line := range strings.Split(script, "\n") {
		if strings.Contains(line, "udp sport 51820 accept") {
			count++
		}
	}
	if count != 1 {
		t.Errorf("expected exactly one shared-port sport rule, got %d; script:\n%s", count, script)
	}
	// Both networks' own scoped daddr-set rules must still be present.
	if !hasRule(script, "oifname", `"wg-sdwan-a1b2c3"`, "ip", "daddr", "{", "10.0.0.0/24,", "}", "accept") {
		t.Error("first network's daddr-set rule missing")
	}
	if !hasRule(script, "oifname", `"wg-sdwan-d4e5f6"`, "ip", "daddr", "{", "10.0.1.0/24,", "}", "accept") {
		t.Error("second network's daddr-set rule missing")
	}
}

func TestApplyEgressExtras_NetworkCapTruncatesAndReportsIt(t *testing.T) {
	rec := &mount.RecorderRunner{}
	withTempEgressScriptPath(t)
	networks := make([]EgressNetwork, maxEgressEntries+5)
	for i := range networks {
		networks[i] = EgressNetwork{ListenPort: 40000 + i}
	}
	err := ApplyEgressAllowlistWithExtras(context.Background(), rec, nil, nil, EgressExtras{Networks: networks})
	if err == nil || !strings.Contains(err.Error(), "truncated") {
		t.Fatalf("expected the cap truncation to be reported, got: %v", err)
	}
	script := readEgressScript(t)
	count := 0
	for _, line := range strings.Split(script, "\n") {
		if strings.Contains(line, "sport") {
			count++
		}
	}
	if count != maxEgressEntries {
		t.Errorf("expected exactly %d sport rules (cap enforced), got %d", maxEgressEntries, count)
	}
}

// IMP-13645c4df90a review round item 9: a single network's AllowedIPs list
// is capped independently of the NETWORK count cap above — a hub with many
// spokes (or a misbehaving platform push) must not turn into an unbounded
// set literal for the ONE interface it names.
func TestApplyEgressExtras_AllowedIPsPerNetworkCapTruncatesAndReportsIt(t *testing.T) {
	rec := &mount.RecorderRunner{}
	withTempEgressScriptPath(t)
	cidrs := make([]string, egressAllowedIPsMaxPerNetwork+5)
	for i := range cidrs {
		cidrs[i] = fmt.Sprintf("10.%d.%d.0/24", i/256, i%256)
	}
	extras := EgressExtras{Networks: []EgressNetwork{
		{Interface: "wg-sdwan-a1b2c3", ListenPort: 51820, AllowedIPs: cidrs},
	}}
	err := ApplyEgressAllowlistWithExtras(context.Background(), rec, nil, nil, extras)
	if err == nil || !strings.Contains(err.Error(), "truncated") {
		t.Fatalf("expected the per-network allowed_ips cap truncation to be reported, got: %v", err)
	}
	script := readEgressScript(t)
	count := 0
	for _, line := range strings.Split(script, "\n") {
		count += strings.Count(line, "/24,")
	}
	if count != egressAllowedIPsMaxPerNetwork {
		t.Errorf("expected exactly %d CIDRs in the rendered set (cap enforced), got %d", egressAllowedIPsMaxPerNetwork, count)
	}
	// The sport rule (a DIFFERENT cap entirely) must still land untouched.
	if !hasRule(script, "udp", "sport", "51820", "accept") {
		t.Error("the sport rule must still apply despite the allowed_ips cap")
	}
}

// Under the atomic rebuild, extras/module/protected rules all live in ONE
// nft -f transaction — there is no longer a per-rule nft failure to inject
// (RecorderRunner's StubErr keys on a single argv-based invocation, and the
// only invocation left is `nft -f <path>`). This pins the ATOMICITY
// property itself — an nft -f failure (syntax error, kernel rejection)
// fails the WHOLE apply, never a partial one, and the prior chain is left
// untouched (nothing here can assert on kernel state without a live nft,
// but the Go-level contract — one call, one all-or-nothing result — is
// exactly what StubErr on that one call proves). No extras in THIS
// fixture, deliberately: with extras present, a failure retries WITHOUT
// them (item 4, see TestApplyEgressExtras_NftFailureWithExtrasFallsBackWithoutThem
// just below) — that is a SECOND, intentional invocation, not a broken
// atomicity guarantee, so it needs its own test rather than blurring this
// one's single-invocation assertion.
func TestApplyEgressExtras_NftDashFFailureFailsWholeApplyAtomically(t *testing.T) {
	withTempEgressScriptPath(t)
	rec := &mount.RecorderRunner{
		StubErr: map[string]error{
			"nft -f " + egressStagingPath(): errors.New("boom"),
		},
	}
	err := ApplyEgressAllowlistWithExtras(context.Background(), rec, nil, []string{"203.0.113.9"}, EgressExtras{})
	if err == nil {
		t.Fatal("an nft -f failure must be reported, not swallowed")
	}
	if !strings.Contains(err.Error(), "boom") {
		t.Errorf("expected the underlying nft error to be wrapped through; got %v", err)
	}
	assertSingleNftDashF(t, rec)
}

// IMP-13645c4df90a review round item 4: extras must never hold a
// well-formed module/protected-host apply hostage. The FIRST nft -f (with
// extras) fails; the retry (without them, same staging path — StubErrOnce
// is what makes "fail once, then succeed" expressible here at all, since a
// plain StubErr would also catch the retry) must succeed, and the returned
// error must name the extras failure without claiming the whole apply
// failed.
func TestApplyEgressExtras_NftFailureWithExtrasFallsBackWithoutThem(t *testing.T) {
	withTempEgressScriptPath(t)
	rec := &mount.RecorderRunner{
		StubErrOnce: map[string]error{
			"nft -f " + egressStagingPath(): errors.New("boom"),
		},
	}
	extras := EgressExtras{Networks: []EgressNetwork{
		{Interface: "wg-sdwan-a1b2c3", ListenPort: 51820, AllowedIPs: []string{"10.0.0.0/24"}},
	}}
	err := ApplyEgressAllowlistWithExtras(context.Background(), rec, nil, []string{"203.0.113.9"}, extras)
	if err == nil {
		t.Fatal("the extras failure must still be reported, even though the fallback apply succeeded")
	}
	if !strings.Contains(err.Error(), "boom") {
		t.Errorf("expected the underlying nft error to be named; got %v", err)
	}

	nftCalls := 0
	for _, inv := range rec.Invocations {
		if inv.Name == "nft" {
			nftCalls++
		}
	}
	if nftCalls != 2 {
		t.Fatalf("expected exactly 2 nft invocations (the failed WITH-extras attempt, then the fallback WITHOUT them), got %d: %+v", nftCalls, rec.Invocations)
	}

	// The fallback script (the one actually staged after the retry) must
	// carry the protected-host rule and must NOT carry the sport rule —
	// extras were genuinely dropped for this tick, not partially applied.
	script := readEgressScript(t)
	if !hasRule(script, "ip", "daddr", "203.0.113.9", "accept") {
		t.Errorf("expected the protected-host rule to survive the fallback; script:\n%s", script)
	}
	if strings.Contains(script, "sport") {
		t.Errorf("expected the extras' sport rule to be ABSENT from the fallback script; script:\n%s", script)
	}
}

// EgressExtras is additive to the module allowlist — a module's own accept
// rules and the SDWAN extras must both survive one ApplyEgressAllowlistWithExtras call.
func TestApplyEgressExtras_SurviveAlongsideModuleAllowlist(t *testing.T) {
	rec := &mount.RecorderRunner{}
	withTempEgressScriptPath(t)
	extras := EgressExtras{Networks: []EgressNetwork{{
		Interface: "wg-sdwan-a1b2c3", ListenPort: 51820, AllowedIPs: []string{"10.0.0.0/24"},
	}}}
	if err := ApplyEgressAllowlistWithExtras(
		context.Background(), rec, []string{"198.51.100.5:443"}, nil, extras,
	); err != nil {
		t.Fatalf("ApplyEgressAllowlistWithExtras: %v", err)
	}
	script := readEgressScript(t)
	if !hasRule(script, "ip", "daddr", "198.51.100.5", "tcp", "dport", "443", "accept") {
		t.Error("module allowlist rule missing alongside sdwan extras")
	}
	if !hasRule(script, "udp", "sport", "51820", "accept") {
		t.Error("sdwan sport rule missing alongside a module allowlist entry")
	}
	if !hasRule(script, "oifname", `"wg-sdwan-a1b2c3"`, "ip", "daddr", "{", "10.0.0.0/24,", "}", "accept") {
		t.Error("sdwan tunnel-scope rule missing alongside a module allowlist entry")
	}
}
