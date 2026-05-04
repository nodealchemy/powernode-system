// frr_applier.go — slice 9c: write frr.conf and reload FRR for iBGP
// networks. Pattern mirrors nftables_applier.go: write to a 0640
// tempfile (frr group readable), atomic rename to /etc/frr/frr.conf,
// then `systemctl reload frr`.
//
// Single-host model: FRR is a single daemon per host with one
// frr.conf. The platform's Sdwan::Bgp::ConfigCompiler emits BgpConf
// per-peer-per-network; this applier consumes the union of all
// iBGP-enabled networks for the host. v1 simplification: if more than
// one iBGP network's BgpConf is non-empty, we use the FIRST one (works
// correctly when a host participates in a single iBGP network — the
// common case). Multi-network aggregation is a slice 9c.1 enhancement
// once we exercise the common case in production.
//
// Idempotency: we hash the rendered config and compare against the
// last-applied hash; if unchanged, skip the file write + reload.
//
// Slice 9c of the SDWAN plan.

package sdwan

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
)

// FrrApplier abstracts FRR config write + reload so the manager is
// testable. ShellFrrApplier is the production implementation; tests
// can substitute an in-memory recorder.
type FrrApplier interface {
	ApplyConfig(ctx context.Context, cfg *BgpConf) error
	DisableFrr(ctx context.Context) error
}

// ShellFrrApplier writes /etc/frr/frr.conf and reloads frr.service.
type ShellFrrApplier struct {
	// ConfigPath overrides the install path (defaults to /etc/frr/frr.conf)
	ConfigPath string
	// SystemctlBin overrides systemctl for tests
	SystemctlBin string

	mu             sync.Mutex
	lastConfigHash string
}

func NewShellFrrApplier() *ShellFrrApplier {
	return &ShellFrrApplier{
		ConfigPath:   "/etc/frr/frr.conf",
		SystemctlBin: "systemctl",
	}
}

func (a *ShellFrrApplier) ApplyConfig(ctx context.Context, cfg *BgpConf) error {
	if cfg == nil || !cfg.Enabled {
		return a.DisableFrr(ctx)
	}

	// Render — slice 9c v1 takes the platform-provided frr text
	// verbatim. Future versions may locally re-emit from BgpConf if
	// we want client-side tweaks.
	rendered := a.renderConfig(cfg)
	hash := configHash(rendered)

	a.mu.Lock()
	prev := a.lastConfigHash
	a.mu.Unlock()
	if hash == prev {
		// Nothing changed since last apply — skip the file write +
		// reload. This is the hot-path in steady state where iBGP is
		// already running and the topology hasn't shifted.
		return nil
	}

	if err := a.writeConfigAtomic(rendered); err != nil {
		return fmt.Errorf("write frr.conf: %w", err)
	}
	if err := a.reloadFrr(ctx); err != nil {
		return fmt.Errorf("reload frr: %w", err)
	}

	a.mu.Lock()
	a.lastConfigHash = hash
	a.mu.Unlock()
	return nil
}

// DisableFrr — networks all in static mode; stop the daemon and clear
// our last-applied hash so a future reapply triggers a full write.
func (a *ShellFrrApplier) DisableFrr(ctx context.Context) error {
	bin := a.SystemctlBin
	if bin == "" {
		bin = "systemctl"
	}
	// Best-effort stop; ignore errors (systemd may not be present in
	// the netns test environment).
	cmd := exec.CommandContext(ctx, bin, "stop", "frr")
	_, _ = cmd.CombinedOutput()

	a.mu.Lock()
	a.lastConfigHash = ""
	a.mu.Unlock()
	return nil
}

// renderConfig — slice 9c uses the platform-supplied text directly. We
// don't construct frr.conf locally because the platform owns the
// route-reflector / route-policy / address-family decisions. The
// agent's job is to apply the config the platform produces, idempotently.
//
// The cfg passed here contains a `frr_text` field rendered server-side
// by Sdwan::Bgp::ConfigCompiler#render_frr_text. We expose it via the
// JSON tag in BgpConf below.
func (a *ShellFrrApplier) renderConfig(cfg *BgpConf) string {
	if cfg.FrrText != "" {
		return cfg.FrrText
	}
	// Fallback: minimal config from the structured fields — keeps the
	// agent functional even if the platform omits frr_text.
	var buf bytes.Buffer
	fmt.Fprintf(&buf, "frr defaults traditional\n")
	fmt.Fprintf(&buf, "router bgp %d\n", cfg.AsNumber)
	fmt.Fprintf(&buf, " bgp router-id %s\n", cfg.RouterID)
	for _, n := range cfg.Neighbors {
		fmt.Fprintf(&buf, " neighbor %s remote-as %d\n", n.NeighborAddress, n.RemoteAs)
	}
	fmt.Fprintln(&buf, "!")
	return buf.String()
}

// writeConfigAtomic — write to a tempfile in the same directory as
// frr.conf, fsync, then rename. Same-FS rename is atomic on Linux.
// File mode 0640: owner=root rw, group=frr r, others none.
func (a *ShellFrrApplier) writeConfigAtomic(content string) error {
	dir := filepath.Dir(a.ConfigPath)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".frr.conf.")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer func() {
		// Always clean up the tempfile on any error path.
		_ = os.Remove(tmpName)
	}()

	if _, err := tmp.WriteString(content); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmpName, 0o640); err != nil {
		return err
	}
	if err := os.Rename(tmpName, a.ConfigPath); err != nil {
		return err
	}
	return nil
}

func (a *ShellFrrApplier) reloadFrr(ctx context.Context) error {
	bin := a.SystemctlBin
	if bin == "" {
		bin = "systemctl"
	}
	// Prefer reload-or-restart so the first apply (when frr was stopped)
	// brings it up; subsequent applies hot-reload without dropping
	// established sessions.
	cmd := exec.CommandContext(ctx, bin, "reload-or-restart", "frr")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("systemctl reload frr: %w; %s", err, string(out))
	}
	return nil
}

func configHash(content string) string {
	sum := sha256.Sum256([]byte(content))
	return hex.EncodeToString(sum[:])
}
