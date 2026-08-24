package security

import (
	"context"
	"fmt"
	"net"
	"regexp"
	"strconv"
	"strings"

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
func ApplyEgressAllowlistWithProtected(ctx context.Context, runner mount.Runner, allowlist, protectedHosts []string) error {
	// Validate + resolve the whole allowlist BEFORE touching nft at all. Two
	// reasons: (1) injection defense — an entry that violates the contract
	// grammar (whitespace, ';', a newline, a brace) must never reach an nft
	// argv element, since nft(8) re-joins its arguments and re-parses them, so
	// a single hostile element executes a second command as root against this
	// NODE-WIDE chain; (2) availability — building here first means a bad entry
	// aborts with the PRIOR chain still intact, rather than after the chain has
	// been torn down and rebuilt (which would drop every sibling module's egress
	// to default-deny until the bad entry is fixed). Fail closed AND fail
	// non-destructive.
	rules, skipped, err := buildEgressRules(allowlist)
	if err != nil {
		return fmt.Errorf("egress allowlist: %w", err)
	}

	// Step 1: ensure the table exists. nft will skip-on-exists.
	if err := runner.Run(ctx, "nft", "add", "table", "inet", EgressTable); err != nil {
		// Some nft versions return non-zero on already-exists; ignore.
	}
	// Step 2: Install/replace the egress chain.
	chain := "powernode_egress_filter"
	_ = runner.Run(ctx, "nft", "delete", "chain", "inet", EgressTable, chain) // best-effort

	if err := runner.Run(ctx, "nft", "add", "chain", "inet", EgressTable, chain,
		"{", "type", "filter", "hook", "output", "priority", "0", ";", "policy", "drop", ";", "}",
	); err != nil {
		return fmt.Errorf("create egress chain: %w", err)
	}

	// Allow outbound responses for connections initiated against us
	// (inbound SSH/HTTP/etc). Without this, the OUTPUT hook drops every
	// SYN-ACK + reply packet, making the host look network-dead from the
	// outside even though it can still initiate outbound to allowlisted
	// destinations. Standard stateful-firewall practice; first rule so
	// the conntrack lookup happens before any allowlist matching.
	if err := runner.Run(ctx, "nft", "add", "rule", "inet", EgressTable, chain,
		"ct", "state", "established,related", "accept",
	); err != nil {
		return fmt.Errorf("egress ct-state accept: %w", err)
	}

	// Always allow loopback + DNS (modules that don't allow DNS can't
	// resolve their own permitted hosts).
	if err := runner.Run(ctx, "nft", "add", "rule", "inet", EgressTable, chain,
		"oif", "lo", "accept",
	); err != nil {
		return err
	}
	if err := runner.Run(ctx, "nft", "add", "rule", "inet", EgressTable, chain,
		"udp", "dport", "53", "accept",
	); err != nil {
		return err
	}
	if err := runner.Run(ctx, "nft", "add", "rule", "inet", EgressTable, chain,
		"tcp", "dport", "53", "accept",
	); err != nil {
		return err
	}

	// Protected hosts — always reachable regardless of module policy.
	// This is where the platform URL goes: the agent's heartbeat,
	// task-lease, module pulls, and federation traffic ALL run through
	// the host's network stack and pass through this OUTPUT chain. If we
	// don't explicitly allow the platform host, the agent firewalls
	// itself off on the first apply-egress tick. Per-host (no port
	// restriction) so HTTPS+WS+future protocols all pass.
	//
	// nft `ip daddr <hostname>` would in theory resolve at rule-load
	// time, but in practice we've observed silent failures on cloud-VM
	// dogfood runs (DNS not yet stable, nft not using the system
	// resolver, etc.) — the rule install reports success but the
	// hostname is never expanded, leaving the chain with only the static
	// base rules and the agent locked out of its own parent. Always
	// resolve in Go first and emit IP-literal rules; that's the
	// representation nft consumes unambiguously.
	for _, host := range protectedHosts {
		host = strings.TrimSpace(host)
		if host == "" {
			continue
		}
		ips, err := resolveProtectedHost(host)
		if err != nil {
			return fmt.Errorf("egress protected-host %s: %w", host, err)
		}
		for _, ip := range ips {
			family := "ip"
			if ip.To4() == nil {
				family = "ip6"
			}
			if err := runner.Run(ctx, "nft", "add", "rule", "inet", EgressTable, chain,
				family, "daddr", ip.String(), "accept",
			); err != nil {
				return fmt.Errorf("egress protected-host %s (%s): %w", host, ip, err)
			}
		}
	}

	// Emit the pre-validated rules. Values are passed as SEPARATE argv elements
	// (never interpolated into a string), so even a grammar-valid entry never
	// shares a token with an nft keyword — grammar + separate-argv together make
	// injection unexpressible.
	for _, rule := range rules {
		args := append([]string{"add", "rule", "inet", EgressTable, chain}, rule...)
		if err := runner.Run(ctx, "nft", args...); err != nil {
			return fmt.Errorf("egress allow %v: %w", rule, err)
		}
	}
	// Hostnames that did not resolve were SKIPPED (not fatal — see
	// buildEgressRules F6). The resolvable subset + default-deny + protected
	// hosts are already installed; surface the skips so the reconciler logs them
	// via OnError without tearing down a working chain.
	if len(skipped) > 0 {
		return fmt.Errorf("egress: %d allowlist hostname(s) did not resolve and were skipped: %v", len(skipped), skipped)
	}
	return nil
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

func ipFamily(ip net.IP) string {
	if ip.To4() == nil {
		return "ip6"
	}
	return "ip"
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
	// Prefix-form CIDR. net.ParseCIDR accepts ONLY prefix form, so a
	// netmask-form CIDR fails here as the contract requires.
	if strings.Contains(entry, "/") {
		ip, _, perr := net.ParseCIDR(entry)
		if perr != nil {
			return "", 0, nil, fmt.Errorf("not a prefix-form CIDR: %w", perr)
		}
		return "", 0, []egressDaddr{{family: ipFamily(ip), addr: entry}}, nil
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
		return nil, fmt.Errorf("resolve %s: %w", entry, err)
	}
	if len(addrs) == 0 {
		return nil, fmt.Errorf("resolve %s: no A/AAAA records", entry)
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
