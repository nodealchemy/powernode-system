// wg_applier.go — shell-out implementation of the WireGuard data-plane
// applier. Slice 1 deliberately uses `wg`, `ip`, and standard userland
// tools rather than wgctrl-go so the agent's go.mod stays unchanged and
// operator debugging is transparent (the literal commands appear in
// journald). Slice 2 swaps this for a wgctrl-go-backed implementation
// without changing the WgApplier interface.
//
// All operations are idempotent: ApplyInterface tolerates "interface
// already exists" by reconciling, RemoveInterface tolerates "no such
// interface" by treating it as already-removed.
//
// Slice 1 of the SDWAN plan.

package sdwan

import (
	"bufio"
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// WgApplier is the agent's data-plane API surface. Production wraps
// `wg` + `ip`; tests inject a noop implementation.
type WgApplier interface {
	// ApplyInterface (re)configures the interface to match cfg. If the
	// interface doesn't exist, it's created. If it exists with the
	// wrong settings, they're updated. Idempotent.
	ApplyInterface(ctx context.Context, cfg InterfaceConf, peers []PeerConf, privateKey string) error

	// ApplyRoutes installs/reaps kernel routes for peers' AllowedIPs —
	// IMP-470b28a77962. Deliberately a SEPARATE step from ApplyInterface
	// (see ApplyInterface's implementation doc, review round B2): the
	// manager calls this on its own, right after ApplyInterface
	// succeeds, so a route failure can never skip apply_firewall,
	// apply_nat, read_actual or EgressContributions the way folding it
	// into ApplyInterface's own error used to.
	ApplyRoutes(ctx context.Context, cfg InterfaceConf, peers []PeerConf) error

	// RemoveInterface tears down the interface. Tolerates "doesn't exist".
	RemoveInterface(ctx context.Context, name string) error

	// ReadActualState parses `wg show` output for the named interface.
	ReadActualState(ctx context.Context, name string) (*ActualInterfaceState, error)

	// ListSdwanInterfaces returns every wg-sdwan-* interface currently up.
	ListSdwanInterfaces(ctx context.Context) ([]string, error)
}

// ShellApplier shells out to `wg` and `ip`. Default WgApplier in the
// production agent.
type ShellApplier struct {
	// WgPath / IpPath default to "wg" / "ip" — overridable for tests.
	WgPath string
	IpPath string
}

func NewShellApplier() *ShellApplier {
	return &ShellApplier{WgPath: "wg", IpPath: "ip"}
}

func (a *ShellApplier) wg() string {
	if a.WgPath != "" {
		return a.WgPath
	}
	return "wg"
}

func (a *ShellApplier) ip() string {
	if a.IpPath != "" {
		return a.IpPath
	}
	return "ip"
}

// ApplyInterface is the main reconcile entrypoint. It:
//  1. Creates the wg interface (idempotent: ignores EEXIST).
//  2. Sets the link MTU + brings it up (idempotent: skipped when a
//     read of the current state already matches).
//  3. Assigns the IPv6 host address (idempotent: ignores EEXIST).
//  4. Converges the wg config (private key + listen port + peers) via
//     `wg syncconf` from a temp file — never as a CLI argument so the
//     private key never appears in `ps`/shell history.
//
// VRF routes for peer AllowedIPs (IMP-470b28a77962) are a SEPARATE
// method, ApplyRoutes, deliberately NOT a step of this function — see
// its own doc comment for why (review round B2, BLOCKER).
//
// IMP-82208d22fdd1: this used to run unconditionally on every reconcile
// tick (every ~30s), including steps 2 and 4 even when nothing had
// changed. Step 4 was the destructive one — `wg setconf` REPLACES the
// entire peer set, which resets every peer's session: latest-handshake
// goes to "now" and rx/tx counters restart, even though nothing was
// actually reconfigured. Live symptom: rx/tx frozen at one handshake's
// worth of bytes forever while last_handshake_at kept refreshing.
// `wg syncconf` reads the same setconf-format file (still NOT the
// wg-quick [Interface] Address/DNS form — syncconf doesn't accept that
// either) but diffs against the live peer list at the kernel level and
// only touches what actually changed, so calling it unconditionally on
// every tick is safe: an unchanged config is a no-op for any peer whose
// session is untouched. Steps 2/2a below still needed their own guard
// because `ip link set` has no equivalent "diff before touching"
// behavior of its own — it reissues MTU/up/master unconditionally, so
// WE compute the drift with a `readLinkState` read.
func (a *ShellApplier) ApplyInterface(ctx context.Context, cfg InterfaceConf, peers []PeerConf, privateKey string) error {
	if cfg.Name == "" {
		return errors.New("ApplyInterface: empty interface name")
	}
	if privateKey == "" {
		return errors.New("ApplyInterface: empty private key")
	}
	// A malformed key reaching wg's own config parser gets echoed back
	// in its error text — see the redacted-error handling on the
	// syncconf call below. Rejecting it here, before it's ever written
	// to the conf file or handed to `wg`, is the belt to that suspenders:
	// this error text is guaranteed not to contain privateKey at all,
	// whereas wg's own parser error might.
	if err := validateWgPrivateKey(privateKey); err != nil {
		return err
	}

	// 1. Create the link if missing.
	if !a.linkExists(ctx, cfg.Name) {
		if err := run(ctx, a.ip(), "link", "add", cfg.Name, "type", "wireguard"); err != nil {
			return fmt.Errorf("ip link add %s: %w", cfg.Name, err)
		}
	}

	// Read once, use for both the VRF-master and MTU/up decisions below.
	// state == nil (interface just created, or the read itself failed)
	// means "reissue unconditionally" — both calls below are themselves
	// idempotent at the kernel level, so that fallback is always safe;
	// it just costs an extra no-op call rather than an incorrect skip.
	state := readLinkState(ctx, a.ip(), cfg.Name)

	// 1a. Phase N1a: bind the iface to its network's VRF master device.
	// vrf_applier runs before wg_applier in the manager loop so the
	// VRF exists at this point; we still tolerate an absent VRF
	// (transient state during cutover) by surfacing the error in a way
	// the manager records but does not fail the whole reconcile on.
	//
	// IMP-82208d22fdd1: only reissue `ip link set X master Y` when the
	// current master doesn't already match — plain `ip link set` has no
	// built-in idempotency of its own, unlike `wg syncconf` above.
	// Reissuing it every tick was never destructive (the kernel accepts
	// a redundant `master` set as a no-op); this guard only saves an
	// unnecessary exec per tick, it does not close a correctness gap on
	// its own. The self-correction property from Phase N1a is unchanged:
	// a misconfigured master (state.Master != cfg.VrfName) is still
	// detected and fixed on the very next tick, because we re-read state
	// every call rather than trusting a cached value.
	if cfg.VrfName != "" && (state == nil || state.Master != cfg.VrfName) {
		if err := run(ctx, a.ip(), "link", "set", cfg.Name, "master", cfg.VrfName); err != nil {
			return fmt.Errorf("ip link set %s master %s: %w", cfg.Name, cfg.VrfName, err)
		}
	}

	// 2. MTU + up state. Same reasoning as 1a: only reissue when the
	// current MTU or admin state doesn't already match — read via the
	// state captured above rather than a second `ip link show`.
	mtu := cfg.MTU
	if mtu <= 0 {
		mtu = 1420
	}
	if state == nil || state.MTU != mtu || !state.Up {
		if err := run(ctx, a.ip(), "link", "set", cfg.Name, "mtu", strconv.Itoa(mtu), "up"); err != nil {
			return fmt.Errorf("ip link set %s: %w", cfg.Name, err)
		}
	}

	// 3. IPv6 host address. `ip addr add` is treated as idempotent: the
	//    "already there" outcome shows up under TWO different messages
	//    depending on iproute2 version:
	//      - older: "RTNETLINK answers: File exists"
	//      - newer (iproute2 6.x+): "Error: ipv6: address already assigned."
	//    Without matching both, the agent's reconcile loop surfaced the
	//    new-iproute2 message every 30 seconds on hosts that already had
	//    the address (every steady-state tick after first apply). Spam-
	//    free reconcile + faithful failure surfacing for ANY OTHER error.
	if cfg.Address != "" {
		if err := run(ctx, a.ip(), "-6", "addr", "add", cfg.Address, "dev", cfg.Name); err != nil &&
			!isIPAddrAddAlreadyExistsErr(err.Error()) {
			return fmt.Errorf("ip addr add %s on %s: %w", cfg.Address, cfg.Name, err)
		}
	}

	// 4. WireGuard config. Build a wg-setconf-format file (syncconf reads
	//    the identical format — see the doc comment above) in a tempdir
	//    with mode 0600 so the private key never hits a shared shell-history.
	confPath, err := writeWgConfFile(cfg, peers, privateKey)
	if err != nil {
		return fmt.Errorf("write wg conf: %w", err)
	}
	defer os.Remove(confPath)

	// IMP-82208d22fdd1: syncconf, not setconf — see the doc comment on
	// ApplyInterface for why setconf's full-replace semantics were the
	// actual defect. Called unconditionally every tick; that's fine
	// because syncconf itself is the drift check for the peer set (it
	// diffs against the live kernel state before touching anything),
	// unlike the ip link steps above which needed us to compute drift.
	//
	// Uses runWgSyncconfRedacted, not the ordinary run() helper: this is
	// the one call in the package whose input includes a private key,
	// and wg's own config parser echoes a malformed value back in its
	// error text. run() embeds CombinedOutput() in the returned error,
	// which the manager's recordError plumbs into the heartbeat — that
	// would leak the key off the node. validateWgPrivateKey above
	// rejects an obviously-malformed key before we ever get here; this
	// is the second layer, for whatever it doesn't catch.
	if err := runWgSyncconfRedacted(ctx, a.wg(), cfg.Name, confPath); err != nil {
		return err
	}

	return nil
}

// ApplyRoutes installs and reaps kernel routes for cfg's peers'
// AllowedIPs — IMP-470b28a77962. See route_applier.go's package doc for
// what and why.
//
// Review round B2 (BLOCKER): deliberately NOT part of ApplyInterface.
// It used to run as ApplyInterface's own last step, so a route error
// became ApplyInterface's return value — and the manager's reconcile
// loop `continue`s past ANY apply_interface error, which skipped
// apply_firewall, apply_nat AND read_actual for the whole network over
// one bad AllowedIPs entry or a transient `ip route` failure. That's
// worse than the missing-route bug this task fixes: no peer reports,
// healthy_peers goes null, and EgressContributions' ListenPort silently
// drops to 0 — which removes the WG egress allow on a default-deny
// host. The manager now calls this as its own step
// ("apply_routes:<iface>"), right after apply_interface succeeds, with
// `_ =` (same pattern as apply_firewall/apply_nat) so its error is
// recorded but never gates what comes after it.
func (a *ShellApplier) ApplyRoutes(ctx context.Context, cfg InterfaceConf, peers []PeerConf) error {
	return reconcilePeerRoutes(ctx, a.ip(), cfg.Name, cfg.VrfName, peers)
}

// validateWgPrivateKey rejects anything that isn't a syntactically valid
// WireGuard private key (32 raw bytes, standard base64) BEFORE it's
// written to the conf file or handed to `wg`. See the doc comment on its
// call site for why this matters beyond input hygiene: it's the layer
// that's guaranteed never to echo the bad value back.
func validateWgPrivateKey(key string) error {
	decoded, err := base64.StdEncoding.DecodeString(key)
	if err != nil || len(decoded) != 32 {
		return errors.New("ApplyInterface: private key is not a valid base64-encoded 32-byte WireGuard key")
	}
	return nil
}

// runWgSyncconfRedacted runs `wg syncconf <ifname> <confPath>` without
// ever capturing its stdout/stderr — see the call site's doc comment for
// why: wg's own parser can echo a malformed private key back in its
// error text, and that text would otherwise flow into the manager's
// recordError and out through the heartbeat. The tradeoff is a less
// specific error message on a genuine (non-key) failure — e.g. a
// permissions problem — which is accepted here because this is the only
// call in the package whose input includes key material.
func runWgSyncconfRedacted(ctx context.Context, wgPath, ifname, confPath string) error {
	cmd := exec.CommandContext(ctx, wgPath, "syncconf", ifname, confPath)
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("wg syncconf %s failed: %s", ifname, err)
	}
	return nil
}

func (a *ShellApplier) RemoveInterface(ctx context.Context, name string) error {
	if !a.linkExists(ctx, name) {
		return nil
	}
	return run(ctx, a.ip(), "link", "delete", name)
}

// ReadActualState invokes `wg show <iface> dump` and parses the
// machine-readable output. Format (one line per peer; first line is the
// interface):
//
//	<priv-redacted>\t<pubkey>\t<listen-port>\t<fwmark>
//	<pubkey>\t<preshared>\t<endpoint>\t<allowed-ips>\t<latest-handshake-unix>\t<rx>\t<tx>\t<keepalive>
func (a *ShellApplier) ReadActualState(ctx context.Context, name string) (*ActualInterfaceState, error) {
	out, err := capture(ctx, a.wg(), "show", name, "dump")
	if err != nil {
		return nil, fmt.Errorf("wg show %s dump: %w", name, err)
	}

	state := &ActualInterfaceState{Name: name}
	first := true
	scanner := bufio.NewScanner(strings.NewReader(out))
	for scanner.Scan() {
		fields := strings.Split(scanner.Text(), "\t")
		if first {
			first = false
			if len(fields) >= 3 {
				state.PublicKey, _ = fields[1], ""
				if port, err := strconv.Atoi(fields[2]); err == nil {
					state.ListenPort = port
				}
			}
			continue
		}
		if len(fields) < 8 {
			continue
		}
		peer := ActualPeerState{
			PublicKey:  fields[0],
			Endpoint:   fields[2],
			AllowedIPs: splitNonEmpty(fields[3], ","),
		}
		if ts, err := strconv.ParseInt(fields[4], 10, 64); err == nil && ts > 0 {
			peer.LastHandshakeAt = time.Unix(ts, 0)
		}
		if rx, err := strconv.ParseInt(fields[5], 10, 64); err == nil {
			peer.RxBytes = rx
		}
		if tx, err := strconv.ParseInt(fields[6], 10, 64); err == nil {
			peer.TxBytes = tx
		}
		state.Peers = append(state.Peers, peer)
	}

	// Address pulled from `ip -6 addr show <name>` — wg-show doesn't carry it.
	if addr := a.firstInet6Addr(ctx, name); addr != "" {
		state.Address = addr
	}

	return state, nil
}

func (a *ShellApplier) ListSdwanInterfaces(ctx context.Context) ([]string, error) {
	out, err := capture(ctx, a.wg(), "show", "interfaces")
	if err != nil {
		return nil, fmt.Errorf("wg show interfaces: %w", err)
	}
	var names []string
	for _, name := range strings.Fields(strings.TrimSpace(out)) {
		if strings.HasPrefix(name, "wg-sdwan-") {
			names = append(names, name)
		}
	}
	return names, nil
}

// ------------------------------------------------------------------
// Helpers
// ------------------------------------------------------------------

func (a *ShellApplier) linkExists(ctx context.Context, name string) bool {
	if err := run(ctx, a.ip(), "link", "show", name); err != nil {
		return false
	}
	return true
}

func (a *ShellApplier) firstInet6Addr(ctx context.Context, name string) string {
	out, err := capture(ctx, a.ip(), "-6", "-o", "addr", "show", "dev", name)
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(out, "\n") {
		fields := strings.Fields(line)
		// "1: lo    inet6 ::1/128 scope host" → field[3] is "::1/128"
		if len(fields) >= 4 && fields[2] == "inet6" {
			return fields[3]
		}
	}
	return ""
}

// writeWgConfFile composes the `wg setconf`-format file and writes it
// with mode 0600 to a temp path. Returns the path; caller is responsible
// for os.Remove() on it.
func writeWgConfFile(cfg InterfaceConf, peers []PeerConf, privateKey string) (string, error) {
	var b strings.Builder
	fmt.Fprintln(&b, "[Interface]")
	fmt.Fprintf(&b, "PrivateKey = %s\n", privateKey)
	if cfg.ListenPort > 0 {
		fmt.Fprintf(&b, "ListenPort = %d\n", cfg.ListenPort)
	}
	for _, p := range peers {
		fmt.Fprintln(&b)
		fmt.Fprintln(&b, "[Peer]")
		fmt.Fprintf(&b, "PublicKey = %s\n", p.PublicKey)
		if len(p.AllowedIPs) > 0 {
			fmt.Fprintf(&b, "AllowedIPs = %s\n", strings.Join(p.AllowedIPs, ","))
		}
		// Endpoint is only written when the platform has one — unlike
		// PersistentKeepalive below, omitting it is NOT fixed here.
		// wg's own diffing (via syncconf) leaves an attribute alone when
		// its config-file line is absent, so a peer's endpoint (often
		// learned dynamically as it roams, not authoritative from this
		// file) can't be force-cleared this way regardless. Clearing an
		// endpoint server-side is out of scope for IMP-82208d22fdd1.
		if p.Endpoint != "" {
			fmt.Fprintf(&b, "Endpoint = %s\n", p.Endpoint)
		}
		// IMP-82208d22fdd1: always write PersistentKeepalive, even when
		// it's 0/unset — never omit the line. `wg setconf` rebuilt every
		// peer from scratch, so an omitted line always meant "off" (the
		// zero value). `wg syncconf` only changes an attribute when the
		// file carries a value for it, so omitting the line here used to
		// mean "leave whatever the node already has" — a platform change
		// from 25 to 0/nil never reached the node. Writing `= 0`
		// explicitly is a kernel no-op when it's already 0, so this is
		// safe to do unconditionally on every tick.
		keepalive := 0
		if p.PersistentKeepalive != nil && *p.PersistentKeepalive > 0 {
			keepalive = *p.PersistentKeepalive
		}
		fmt.Fprintf(&b, "PersistentKeepalive = %d\n", keepalive)
	}

	f, err := os.CreateTemp("", "sdwan-wg-*.conf")
	if err != nil {
		return "", err
	}
	if _, err := f.WriteString(b.String()); err != nil {
		f.Close()
		os.Remove(f.Name())
		return "", err
	}
	if err := f.Chmod(0o600); err != nil {
		f.Close()
		os.Remove(f.Name())
		return "", err
	}
	if err := f.Close(); err != nil {
		os.Remove(f.Name())
		return "", err
	}
	return f.Name(), nil
}

func run(ctx context.Context, name string, args ...string) error {
	cmd := exec.CommandContext(ctx, name, args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func capture(ctx context.Context, name string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	out, err := cmd.Output()
	if err != nil {
		return "", err
	}
	return string(out), nil
}

func splitNonEmpty(s, sep string) []string {
	if s == "" || s == "(none)" {
		return nil
	}
	parts := strings.Split(s, sep)
	out := parts[:0]
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}
