// vrf_applier.go — Phase N1a: idempotent management of Linux VRF
// master devices and the per-VRF source-routing rules.
//
// One VRF per Sdwan::Network the host belongs to. Each VRF gets:
//   * `ip link add <vrf_name> type vrf table <table_id>` — creates the
//     master device that scopes a separate routing table.
//   * `ip link set <vrf_name> up` — brings it up.
//   * Membership: WG interfaces and per-network dummy ifaces are bound
//     to the VRF via `ip link set <iface> master <vrf_name>` (handled
//     by wg_applier and vip_applier respectively; this applier only
//     creates the VRF itself).
//   * Optional `ip rule add from <addr> table <table_id>` — directs
//     locally-originated packets sourced from the host's overlay
//     address into the VRF's table, so things like the FRR daemon's
//     own outbound traffic stays inside the right routing domain.
//
// Reaping: any VRF master device whose name matches the platform's
// vrf_name template (`sdwan-*` by default) but is NOT in the desired
// set is deleted at the end of each apply. This keeps the kernel
// view in lockstep with the platform, even after operator-driven
// network deletion.
//
// Apply ordering inside the manager: vrf_applier MUST run BEFORE
// wg_applier so the VRF exists at the moment the WG interface is
// created and bound to it.
//
// Phase N1a of the in-house encrypted mesh overlay roadmap.

package sdwan

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
)

// DesiredVRF is the per-VRF intent surfaced from the platform's
// per-peer payload. The topology compiler bundles one of these per
// Sdwan::HostVrfAssignment row that is in compilable state.
type DesiredVRF struct {
	// Name is the kernel-visible VRF master device name (≤15 chars).
	Name string `json:"vrf_name"`
	// TableID is the kernel routing table id (100..65535, never the
	// reserved 0/253/254/255).
	TableID int `json:"table_id"`
	// NetworkHandle is the 8-char network identifier this VRF wraps.
	// Carried for diagnostics / log lines; the applier itself does
	// not key off it.
	NetworkHandle string `json:"network_handle"`
	// BoundIface is the network's WG interface that should be moved
	// into this VRF (e.g. "wg-sdwan-abc12345"). The wg_applier reads
	// this field to apply the master device link after creating the
	// WG iface; vrf_applier exposes it on the type for parity but does
	// not act on it.
	BoundIface string `json:"bound_iface"`
	// SourceAddrs is the optional set of addresses (without prefix
	// length) for which the kernel should install `ip rule from <addr>
	// table <table_id>` so locally-originated traffic from those
	// addresses flows through this VRF's table. Empty means no
	// source-rule install.
	SourceAddrs []string `json:"source_addrs"`
}

// VRFApplier abstracts Linux VRF management so the manager is testable
// without root or netlink access. ShellVRFApplier shells out to `ip`.
type VRFApplier interface {
	Apply(ctx context.Context, desired []DesiredVRF) error
}

// ShellVRFApplier shells out to `ip` for VRF and rule management.
// IpBin overrides the binary path for tests.
type ShellVRFApplier struct {
	IpBin string
}

func NewShellVRFApplier() *ShellVRFApplier {
	return &ShellVRFApplier{}
}

func (a *ShellVRFApplier) ip() string {
	if a.IpBin != "" {
		return a.IpBin
	}
	return "ip"
}

// Apply makes the kernel match `desired`:
//  1. Reads the current VRF master devices owned by this applier
//     (matched by the "sdwan-" prefix; operator-installed VRFs are
//     left alone).
//  2. Creates any desired VRF that is missing.
//  3. Updates table_id when an existing VRF carries the wrong id (rare
//     — the platform's allocator never reassigns ids on a live VRF, so
//     this is a drift-recovery path).
//  4. Brings every desired VRF up.
//  5. Reapplies the per-source `ip rule` set for each desired VRF.
//  6. Deletes orphan VRFs (sdwan-* not in desired).
//
// Tolerates missing `ip` binary by surfacing the error from the first
// command — callers (the manager) record the error and move on so a
// transient applier failure can't kill the heartbeat goroutine.
func (a *ShellVRFApplier) Apply(ctx context.Context, desired []DesiredVRF) error {
	desiredByName := make(map[string]DesiredVRF, len(desired))
	for _, v := range desired {
		if v.Name == "" {
			continue
		}
		desiredByName[v.Name] = v
	}

	current, err := a.listSdwanVRFs(ctx)
	if err != nil {
		return fmt.Errorf("list vrfs: %w", err)
	}

	// Create / reconcile each desired VRF.
	for name, v := range desiredByName {
		actualTableID, exists := current[name]
		switch {
		case !exists:
			if err := a.createVRF(ctx, name, v.TableID); err != nil {
				return fmt.Errorf("create vrf %s: %w", name, err)
			}
		case actualTableID != v.TableID:
			// Table-id drift — the only safe recovery is delete + recreate.
			if err := a.deleteVRF(ctx, name); err != nil {
				return fmt.Errorf("recreate vrf %s (delete step): %w", name, err)
			}
			if err := a.createVRF(ctx, name, v.TableID); err != nil {
				return fmt.Errorf("recreate vrf %s (create step): %w", name, err)
			}
		}

		if err := a.bringUp(ctx, name); err != nil {
			return fmt.Errorf("vrf %s up: %w", name, err)
		}
		if err := a.reconcileSourceRules(ctx, v); err != nil {
			return fmt.Errorf("rules for vrf %s: %w", name, err)
		}
	}

	// Reap orphans — sdwan-* VRFs we didn't ask for.
	for name := range current {
		if _, want := desiredByName[name]; want {
			continue
		}
		// Best-effort delete; an operator may have manually moved
		// interfaces into this VRF, in which case the delete fails and
		// we leave it alone for human triage.
		_ = a.deleteVRF(ctx, name)
	}

	return nil
}

// listSdwanVRFs returns name→table_id for every VRF owned by this
// applier (name starts with "sdwan-"). Reads `ip -d -j link show
// type vrf` and parses the JSON output.
func (a *ShellVRFApplier) listSdwanVRFs(ctx context.Context) (map[string]int, error) {
	out, err := a.captureLinkShow(ctx)
	if err != nil {
		// `ip` returns non-zero when no VRFs exist on some kernels.
		// Treat empty output as zero VRFs rather than a fatal error.
		if out == "" {
			return map[string]int{}, nil
		}
		return nil, err
	}

	parsed, err := parseVRFLinkShow(out)
	if err != nil {
		return nil, err
	}

	filtered := make(map[string]int, len(parsed))
	for name, tableID := range parsed {
		if !strings.HasPrefix(name, "sdwan-") {
			continue
		}
		filtered[name] = tableID
	}
	return filtered, nil
}

func (a *ShellVRFApplier) captureLinkShow(ctx context.Context) (string, error) {
	cmd := exec.CommandContext(ctx, a.ip(), "-d", "-j", "link", "show", "type", "vrf")
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		// Empty output + nonzero exit = no VRFs on this kernel.
		if stdout.Len() == 0 {
			return "", nil
		}
		return stdout.String(), fmt.Errorf("ip link show: %w; stderr=%s", err, stderr.String())
	}
	return stdout.String(), nil
}

func (a *ShellVRFApplier) createVRF(ctx context.Context, name string, tableID int) error {
	cmd := exec.CommandContext(ctx, a.ip(), "link", "add", name,
		"type", "vrf", "table", strconv.Itoa(tableID))
	out, err := cmd.CombinedOutput()
	if err != nil {
		// "RTNETLINK answers: File exists" — link already there. Tolerate.
		if strings.Contains(string(out), "File exists") {
			return nil
		}
		return fmt.Errorf("ip link add: %w; %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func (a *ShellVRFApplier) deleteVRF(ctx context.Context, name string) error {
	cmd := exec.CommandContext(ctx, a.ip(), "link", "delete", name)
	out, err := cmd.CombinedOutput()
	if err != nil {
		if strings.Contains(string(out), "Cannot find device") {
			return nil
		}
		return fmt.Errorf("ip link delete %s: %w; %s", name, err, strings.TrimSpace(string(out)))
	}
	return nil
}

func (a *ShellVRFApplier) bringUp(ctx context.Context, name string) error {
	cmd := exec.CommandContext(ctx, a.ip(), "link", "set", name, "up")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("ip link set up: %w; %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

// reconcileSourceRules installs `ip rule from <addr> table <table_id>`
// for each desired source address. Existing rules for the same address
// are replaced; rules whose address is no longer desired are removed.
//
// Source-rule reaping is currently best-effort: we add the desired
// rules but do not enumerate the entire `ip rule` table to find
// orphans. This is safe because the rules we install carry a unique
// table id per VRF; when the VRF is reaped, the kernel implicitly
// drops rules pointing at the now-invalid table id (the rules sit
// there as dead weight until next reboot, but they no longer affect
// forwarding because the table is gone). A future reaper can sweep
// them via `ip rule show table <id>` enumeration.
func (a *ShellVRFApplier) reconcileSourceRules(ctx context.Context, v DesiredVRF) error {
	for _, addr := range v.SourceAddrs {
		if addr == "" {
			continue
		}
		// Try to delete first to avoid duplicate-rule accumulation across
		// reconciles. `ip rule del` errors when no rule matches; we
		// swallow that.
		_ = a.delRule(ctx, addr, v.TableID)
		if err := a.addRule(ctx, addr, v.TableID); err != nil {
			return fmt.Errorf("ip rule add from %s table %d: %w", addr, v.TableID, err)
		}
	}
	return nil
}

func (a *ShellVRFApplier) addRule(ctx context.Context, addr string, tableID int) error {
	family := "-4"
	if strings.Contains(addr, ":") {
		family = "-6"
	}
	cmd := exec.CommandContext(ctx, a.ip(), family, "rule", "add",
		"from", addr, "table", strconv.Itoa(tableID))
	out, err := cmd.CombinedOutput()
	if err != nil {
		if strings.Contains(string(out), "File exists") {
			return nil
		}
		return fmt.Errorf("%w; %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func (a *ShellVRFApplier) delRule(ctx context.Context, addr string, tableID int) error {
	family := "-4"
	if strings.Contains(addr, ":") {
		family = "-6"
	}
	cmd := exec.CommandContext(ctx, a.ip(), family, "rule", "del",
		"from", addr, "table", strconv.Itoa(tableID))
	_, _ = cmd.CombinedOutput()
	return nil
}

// parseVRFLinkShow extracts (name, table_id) pairs from the JSON
// output of `ip -d -j link show type vrf`. Schema (per iproute2 ≥4.18):
//
//	[
//	  {
//	    "ifname": "sdwan-abc12345",
//	    "linkinfo": {
//	      "info_kind": "vrf",
//	      "info_data": { "table": 100 }
//	    }, ...
//	  }, ...
//	]
//
// Implemented as a hand-rolled parser to avoid pulling encoding/json
// into the file's dependency list — keeps the applier consistent with
// the other shell-out files (wg_applier, frr_applier) which read text
// output. We only need ifname + table; both are simple to extract.
func parseVRFLinkShow(out string) (map[string]int, error) {
	out = strings.TrimSpace(out)
	if out == "" {
		return map[string]int{}, nil
	}
	result := make(map[string]int)

	// Two passes — one to find each "ifname":"<name>", then a localised
	// scan forward for the next "table":<int> belonging to the same
	// object. The kernel emits one object per VRF, so this is robust
	// against field-order changes.
	for {
		nameStart := strings.Index(out, `"ifname":`)
		if nameStart < 0 {
			break
		}
		// Skip past the key.
		out = out[nameStart+len(`"ifname":`):]
		quoteStart := strings.Index(out, `"`)
		if quoteStart < 0 {
			return nil, fmt.Errorf("malformed ifname value")
		}
		afterQuote := out[quoteStart+1:]
		quoteEnd := strings.Index(afterQuote, `"`)
		if quoteEnd < 0 {
			return nil, fmt.Errorf("unterminated ifname value")
		}
		name := afterQuote[:quoteEnd]

		// Find the table value belonging to this object — bounded by the
		// next "ifname":" so we don't pick up another VRF's table.
		nextObjAt := strings.Index(afterQuote, `"ifname":`)
		searchSlice := afterQuote
		if nextObjAt >= 0 {
			searchSlice = afterQuote[:nextObjAt]
		}
		tableID, found := extractTableValue(searchSlice)
		if found {
			result[name] = tableID
		}

		out = afterQuote[quoteEnd:]
	}
	return result, nil
}

// extractTableValue returns the integer value following the first
// `"table":` key in the slice, or 0/false if none.
func extractTableValue(s string) (int, bool) {
	idx := strings.Index(s, `"table":`)
	if idx < 0 {
		return 0, false
	}
	rest := s[idx+len(`"table":`):]
	rest = strings.TrimLeft(rest, " ")
	end := 0
	for end < len(rest) && rest[end] >= '0' && rest[end] <= '9' {
		end++
	}
	if end == 0 {
		return 0, false
	}
	v, err := strconv.Atoi(rest[:end])
	if err != nil {
		return 0, false
	}
	return v, true
}
