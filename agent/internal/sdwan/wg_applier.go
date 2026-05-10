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
//  2. Sets the link MTU + brings it up.
//  3. Assigns the IPv6 host address (idempotent: ignores EEXIST).
//  4. Writes the wg config (private key + listen port + peers) via
//     `wg setconf` from a temp file — never as a CLI argument so the
//     private key never appears in `ps`/shell history.
func (a *ShellApplier) ApplyInterface(ctx context.Context, cfg InterfaceConf, peers []PeerConf, privateKey string) error {
	if cfg.Name == "" {
		return errors.New("ApplyInterface: empty interface name")
	}
	if privateKey == "" {
		return errors.New("ApplyInterface: empty private key")
	}

	// 1. Create the link if missing.
	if !a.linkExists(ctx, cfg.Name) {
		if err := run(ctx, a.ip(), "link", "add", cfg.Name, "type", "wireguard"); err != nil {
			return fmt.Errorf("ip link add %s: %w", cfg.Name, err)
		}
	}

	// 1a. Phase N1a: bind the iface to its network's VRF master device.
	// vrf_applier runs before wg_applier in the manager loop so the
	// VRF exists at this point; we still tolerate an absent VRF
	// (transient state during cutover) by surfacing the error in a way
	// the manager records but does not fail the whole reconcile on.
	//
	// Re-binding is idempotent — the kernel accepts `ip link set X
	// master Y` even when X is already mastered by Y. We always issue
	// the command so a misconfigured iface (master pointing at the
	// wrong VRF) self-corrects on the next tick.
	if cfg.VrfName != "" {
		if err := run(ctx, a.ip(), "link", "set", cfg.Name, "master", cfg.VrfName); err != nil {
			return fmt.Errorf("ip link set %s master %s: %w", cfg.Name, cfg.VrfName, err)
		}
	}

	// 2. MTU + state.
	mtu := cfg.MTU
	if mtu <= 0 {
		mtu = 1420
	}
	if err := run(ctx, a.ip(), "link", "set", cfg.Name, "mtu", strconv.Itoa(mtu), "up"); err != nil {
		return fmt.Errorf("ip link set %s: %w", cfg.Name, err)
	}

	// 3. IPv6 host address. `ip addr add` errors with "RTNETLINK: File
	//    exists" on duplicate — treat as success.
	if cfg.Address != "" {
		if err := run(ctx, a.ip(), "-6", "addr", "add", cfg.Address, "dev", cfg.Name); err != nil &&
			!strings.Contains(err.Error(), "File exists") {
			return fmt.Errorf("ip addr add %s on %s: %w", cfg.Address, cfg.Name, err)
		}
	}

	// 4. WireGuard config. Build a wg-setconf-format file in a tempdir
	//    with mode 0600 so the private key never hits a shared shell-history.
	confPath, err := writeWgConfFile(cfg, peers, privateKey)
	if err != nil {
		return fmt.Errorf("write wg conf: %w", err)
	}
	defer os.Remove(confPath)

	if err := run(ctx, a.wg(), "setconf", cfg.Name, confPath); err != nil {
		return fmt.Errorf("wg setconf %s: %w", cfg.Name, err)
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
		if p.Endpoint != "" {
			fmt.Fprintf(&b, "Endpoint = %s\n", p.Endpoint)
		}
		if p.PersistentKeepalive != nil && *p.PersistentKeepalive > 0 {
			fmt.Fprintf(&b, "PersistentKeepalive = %d\n", *p.PersistentKeepalive)
		}
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
