package runtime

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/probe"
	"github.com/nodealchemy/powernode-system/agent/internal/sdwan"
	"github.com/nodealchemy/powernode-system/agent/internal/signingaudit"
	"github.com/nodealchemy/powernode-system/agent/internal/transport"
)

// HeartbeatPayload is the body the agent POSTs to /status/heartbeat.
// Mirrors the platform's M0.M NodeInstance#record_heartbeat! parameters.
type HeartbeatPayload struct {
	BootID        string            `json:"boot_id"`
	AgentVersion  string            `json:"agent_version"`
	Architecture  string            `json:"architecture,omitempty"`
	UptimeSeconds int64             `json:"uptime_seconds"`
	ModuleDigests map[string]string `json:"module_digests"` // node_module_id → oci_digest
	// PendingModuleDigests (M9, review round 9) names the digest an
	// in-place upgrade is CURRENTLY MID-WAY toward for a module still
	// reporting its OLD digest in ModuleDigests above — set once
	// upgradeModule's step 4 starts restarting units (so a partial
	// multi-unit restart, e.g. one unit landed on the new binary and a
	// LATER one failed, is never invisible) and cleared once the upgrade
	// actually commits. Omitted (nil map, omitempty) for a module with no
	// upgrade in flight — never an empty-but-present block, which would
	// read as "checked, nothing pending" rather than "not applicable".
	PendingModuleDigests map[string]string `json:"pending_module_digests,omitempty"`
	MountState           string            `json:"mount_state"` // "mounted" | "unmounted" | "transitioning"
	LoadAverage          string            `json:"load_average,omitempty"`
	// MemoryFreeKB is *int64, not omitempty: a nil pointer (not measured —
	// /proc/meminfo missing or unparseable) marshals to `null`/absent-shaped
	// distinct from an explicit 0, which is the most alarming reading a node
	// can report (memory exhausted) and must never be indistinguishable from
	// "not measured". See buildHeartbeat / readMemAvailableKB.
	MemoryFreeKB *int64 `json:"memory_free_kb"`
	// CPUPct is percent-busy across the interval since the PREVIOUS heartbeat,
	// measured on-node from /proc/stat deltas (APO-2a). *float64 and not
	// omitempty for exactly the MemoryFreeKB reason: 0.0 is a genuinely idle
	// node — a real reading — and must never be indistinguishable from "not
	// measured". nil (marshalled as null) is the honest answer for the first
	// heartbeat of a process, an unreadable /proc/stat, and a counter reset.
	//
	// This is NOT derived from LoadAverage, here or on the server
	// (IMP-938ee27f4921): a load average folds in I/O-wait run-queue length
	// and needs a core count to become a percentage. See cpuSampler.
	CPUPct     *float64                `json:"cpu_pct"`
	SdwanState []sdwan.HeartbeatStatus `json:"sdwan_state,omitempty"`
	// SdwanOvnState is the most recent OVN NB plan replay observation
	// (IMP-57e9a90598ee). Top-level rather than nested in SdwanState
	// because the NB replay is host-scoped, not per-network. nil — and
	// omitted from the wire — means NOT MEASURED: this host has never
	// replayed an NB plan this boot (lightweight profile, no servable
	// deployment, or the OVN subsystem's precondition is absent). The
	// platform's Sdwan::Ovn::DeploymentReconciler consumes it to drive
	// the OvnDeployment lifecycle (degraded/readopt), so absence must
	// never be synthesized into an empty-but-present block.
	SdwanOvnState *sdwan.ObservedOvnNbState `json:"sdwan_ovn_state,omitempty"`
	// ModuleVerifyState is the result of running each attached module's
	// manifest-declared `verify:` probes (IMP-3855ff9908f2). nil — and
	// omitted from the wire — means NOT MEASURED: no module on this node
	// declares a probe, or the probe runner has not completed a pass yet.
	// The platform's System::ModuleVerifyStateWriter must never synthesize
	// an absent block into an empty-but-present one, because "nothing to
	// verify" and "verified, nothing wrong" are different facts.
	//
	// Per-shell FACTS only, never a roll-up: the server derives the verdict,
	// so a report covering one shell can never be mistaken for a pass. See
	// internal/probe.
	ModuleVerifyState []probe.ModuleReport `json:"module_verify_state,omitempty"`
	// ModuleSigningAudit is what the module-signing ladder's AUDIT rungs
	// observed on this node (IMP-c52b5c2d6cbf): one entry per DISTINCT finding
	// from verify:module_signature_audit / verify:module_fsverity_audit, each
	// naming a blob an enforcing rung would have refused, with a repeat count —
	// plus verify:module_signing / verify:module_signing_keys, the measurement's
	// own failure modes, which say a quiet reading here is worthless.
	// Before this block those findings reached only the node's stderr, so the
	// ladder's default stayed `off` — no one could see fleet-wide whether
	// enforcing was safe.
	//
	// A POINTER, and the payload a struct, both deliberately: `omitempty`
	// erases an empty SLICE exactly as it erases a nil one, so a slice here
	// would make a quiet node byte-identical to a node that never measured —
	// and the ABSENCE of findings is the whole justification for enforcing.
	// nil (omitted) means NOT MEASURED: signing is off. A present block with an
	// empty findings list means audit ran and this node is QUIET. The platform's
	// System::ModuleSigningAuditWriter keeps those apart and must never
	// synthesize one into the other.
	ModuleSigningAudit *signingaudit.Observation `json:"module_signing_audit,omitempty"`
	// Capabilities is the agent-detected kernel capability set
	// (erofs, overlayfs, fs-verity). The server records this on every
	// heartbeat for fleet introspection ("which nodes can mount
	// erofs?") and as a sanity gate before reconciling modules onto
	// a node. Detection runs once at service startup (see
	// internal/runtime/capabilities.go) and is stable across reboots
	// until the kernel changes.
	Capabilities *NodeCapabilities `json:"node_capabilities,omitempty"`
	// BootedImageGitSHA is the git_sha baked into the disk image this node
	// booted from (campaign 019f505f). Read once at service startup from the UKI
	// kernel cmdline (powernode.image_git_sha=); stable for the life of the boot,
	// so it's snapshotted rather than re-read each tick. The platform compares it
	// against the promoted image's git_sha to detect boot-image drift. Empty
	// (omitted) on netboot / non-UKI / pre-019f505f images that don't bake it —
	// the server reads that as "unknown", never drift.
	BootedImageGitSHA string `json:"booted_image_git_sha,omitempty"`
	// BootedFromLKG is true when this boot's ComposeForPivot fell back to the
	// frozen boot-LKG because the control plane was unreachable (#39 Level-1
	// boot-independence). Read from the boot breadcrumb; the platform surfaces it
	// so an operator can SEE which nodes are surviving on a frozen composition.
	BootedFromLKG bool `json:"booted_from_lkg,omitempty"`
	// LKGAgeSeconds is the age of the boot-LKG this node booted from (only
	// meaningful when BootedFromLKG). Lets the platform ALERT on a node running
	// an increasingly-stale frozen composition after its control plane went away.
	LKGAgeSeconds int64 `json:"lkg_age_seconds,omitempty"`
	// LKGPresent + LKGConfirmedAt + LKGModuleCount are ARM-telemetry (#39 HIGH-1):
	// emitted on EVERY boot's heartbeat (not just fallback boots) from the
	// on-disk frozen LKG, so an operator can VERIFY a node is armed with a valid
	// last-known-good BEFORE decommissioning its control plane (#14). Absence of
	// lkg_present=true means "not armed" — a decommission-blocking signal.
	LKGPresent     bool   `json:"lkg_present,omitempty"`
	LKGConfirmedAt string `json:"lkg_confirmed_at,omitempty"`
	LKGModuleCount int    `json:"lkg_module_count,omitempty"`
	// BootIncomplete is true when THIS boot composed an incomplete assigned set
	// (a data module was dropped at compose). The capturer skips LKG capture on
	// such a boot; this field makes the degraded boot directly visible.
	BootIncomplete bool `json:"boot_incomplete,omitempty"`
	// PivotConfinementOmitted names the confinements the direct_kernel/pivot
	// boot path does NOT enforce, so an operator reading a module's security
	// block can tell what is actually in force on a pivoted (hub) node rather
	// than inferring it from the manifest (IMP-01a02f70-9bfb, F3). Seccomp,
	// PrivateUsers, the privileged gate, and (IMP-caef5c00d63f phase 2) the
	// capability bounding set are now all applied on the pivot path; still
	// omitted there: mandatory access control (SELinux/AppArmor profiles are
	// never loaded on the pivot path). Populated only on pivot (native
	// root-mode) nodes; nil/omitted on cloud_init nodes, where attachModule
	// enforces the full set. Absence therefore means "full set enforced (or
	// not a pivot node)", never "unknown".
	PivotConfinementOmitted []string `json:"pivot_confinement_omitted,omitempty"`
	// PivotSecurityFailClosedUnits names every unit the pivot-compose path
	// refused to enable THIS boot because a sibling security drop-in
	// (capabilities.conf / userns.conf / seccomp) failed to write
	// (IMP-caef5c00d63f phase 3, review HIGH-1/MEDIUM-1). Read from the boot
	// breadcrumb (BootComposedBreadcrumb.SecurityFailClosedUnits), so it
	// covers the boot that just happened, not a live re-check. A unit named
	// here is NOT running: this heartbeat must never ALSO report it as
	// capability-confined (PivotConfinementOmitted's absence means "full set
	// enforced OR not applicable" — a fail-closed unit is neither, it simply
	// never started). Empty/omitted means no fail-closed refusal happened on
	// this boot, never "not measured" — renderPivotUnits always runs on a
	// pivot boot.
	PivotSecurityFailClosedUnits []string `json:"pivot_security_fail_closed_units,omitempty"`
	// RuntimeSecurityFailClosedUnits is PivotSecurityFailClosedUnits'
	// sibling for the LIVE (cloud-init/pivot-reconcile) attach path
	// (IMP-caef5c00d63f phase 4): units attachModule currently REFUSES to
	// (re)attach/start because a non-exempt security drop-in write failed on
	// THIS tick's reconcile, not at boot. Unlike a pivot-boot refusal (never
	// started, full stop), a unit named here on a RE-attach may already be
	// running — the agent never stops it (round 5, G1: doing so was
	// unrecoverable on a self-hosted node, and enforced a stricter guarantee
	// than a successful write ever gives), it simply keeps running under
	// whatever confinement it already had, never a weaker one this refusal
	// would have applied. A separate field, not the same one, because the two
	// describe different facts with different lifetimes — Pivot's is a
	// one-time statement about the boot that just happened (persisted via the
	// boot breadcrumb, re-read every tick until
	// the next boot); Runtime's is live and can clear on the very next
	// successful reconcile. Read straight from the Reconciler
	// (SecurityFailClosedUnits), not a breadcrumb — there is no boot event to
	// persist across for a condition that can appear and clear mid-uptime.
	// Empty/omitted means no live runtime-path refusal right now.
	RuntimeSecurityFailClosedUnits []string `json:"runtime_security_fail_closed_units,omitempty"`
	// RuntimeConfinementStaleUnits (round Y, IMP-caef5c00d63f) names units
	// the most recently completed reconcile pass found running with
	// capabilities that diverge from their manifest's current declaration —
	// either direction (wider, a genuine gap the agent may or may not have
	// been permitted to self-heal via a restart; narrower, a harmless
	// self-narrowing) — see confinement_probe.go's own doc for the
	// predicate. Read straight from the Reconciler (ConfinementStaleUnits),
	// recomputed fresh every tick from /proc, never persisted: a fresh
	// agent process simply omits this until its own first pass runs.
	// Empty/omitted means every attached, N4-eligible unit's running
	// capabilities currently match what its manifest declares.
	RuntimeConfinementStaleUnits []string `json:"runtime_confinement_stale_units,omitempty"`
	// AssignmentDeferral (IMP-9f4e162d9ed1) lists the live conditions in which
	// the reconciler is KEEPING modules it would otherwise detach, or skipping
	// the identity render, because the platform's answer cannot be trusted (see
	// assignment_deferral.go). Each carries how long that unbroken run has lasted
	// as a duration, so the platform can tell a one-tick blip from a node stuck
	// on a composition that no longer matches its assignment. Read straight from
	// the Reconciler, recomputed every pass, never persisted. Empty/omitted
	// means no deferral is in force, or an agent too old to say; the platform
	// must treat absence as UNREPORTED, never as a measured all-clear.
	AssignmentDeferral []AssignmentDeferralReport `json:"assignment_deferral,omitempty"`
	// AgentConditions (IMP-a6d61b01490d) lists the standing conditions the agent
	// keeps off the failure path on purpose but an operator must see: a
	// known-degraded unit and a refused sudoers grant today (agent_conditions.go).
	// It rides the heartbeat, not a one-shot fleet event, because the heartbeat
	// is the lane that carries STANDING state and is resent every tick, which is
	// what lets a cleared condition be reported as cleared. A POINTER so the
	// three states stay distinct on the wire: nil is omitted and means the agent
	// has not measured yet or is too old to report (the platform must read it as
	// UNREPORTED); a non-nil empty list is sent as [] and means measured, none.
	AgentConditions *[]AgentCondition `json:"agent_conditions,omitempty"`
	// SSHHostKeys are this host's SSH host PUBLIC keys, read from
	// /etc/ssh/ssh_host_*_key.pub (IMP-190834701b0a; see hostkeys.go). The
	// platform verifies every SSH connection it makes to this node against
	// them. nil (omitted) means NOT MEASURED: no valid .pub file was found.
	// It never means "this host has no keys", and it is never sent as an
	// empty list.
	SSHHostKeys []HostKey `json:"ssh_host_keys,omitempty"`
}

// HeartbeatResponse is what the platform sends back. Includes a hint at
// the next poll interval (lets the platform throttle agents under load).
type HeartbeatResponse struct {
	Success bool `json:"success"`
	Data    struct {
		Acknowledged    bool `json:"acknowledged"`
		PendingTasks    int  `json:"tasks_pending"`
		NextPollSeconds int  `json:"next_poll_seconds"`
	} `json:"data"`
}

// Heartbeat sends one HeartbeatPayload + parses the response.
type Heartbeater struct {
	Client       *transport.Client
	StartedAt    time.Time
	BuildPayload func() HeartbeatPayload // closure that gathers fresh runtime metrics
	// PostSend, if non-nil, is invoked after each successful heartbeat. The
	// service uses it to refresh ancillary state (e.g. authorized_keys) on the
	// same cadence without spinning up a separate goroutine.
	PostSend func()
}

// Send delivers one heartbeat. Returns the parsed response so callers
// can adjust their poll interval based on platform feedback.
func (h *Heartbeater) Send(ctx context.Context) (*HeartbeatResponse, error) {
	payload := h.BuildPayload()
	if h.StartedAt.IsZero() {
		h.StartedAt = time.Now()
	}
	payload.UptimeSeconds = int64(time.Since(h.StartedAt).Seconds())

	body, err := json.Marshal(payload)
	if err != nil {
		return nil, fmt.Errorf("marshal heartbeat: %w", err)
	}

	resp, err := postJSON(ctx, h.Client, "/api/v1/system/node_api/status/heartbeat", body)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 64*1024))

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("heartbeat status %d: %s", resp.StatusCode, string(respBody))
	}
	var hr HeartbeatResponse
	if err := json.Unmarshal(respBody, &hr); err != nil {
		return nil, fmt.Errorf("parse heartbeat response: %w", err)
	}
	return &hr, nil
}

// Run loops Send + sleep until ctx is canceled. The next-poll-seconds
// hint from the platform is honored when present; otherwise falls back
// to defaultInterval.
func (h *Heartbeater) Run(ctx context.Context, defaultInterval time.Duration, onError func(error)) {
	if defaultInterval <= 0 {
		defaultInterval = 30 * time.Second
	}
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		nextInterval := defaultInterval
		hr, err := h.Send(ctx)
		if err != nil {
			if onError != nil {
				onError(err)
			}
		} else {
			if hr.Data.NextPollSeconds > 0 {
				nextInterval = time.Duration(hr.Data.NextPollSeconds) * time.Second
			}
			if h.PostSend != nil {
				h.PostSend()
			}
		}

		select {
		case <-ctx.Done():
			return
		case <-time.After(nextInterval):
		}
	}
}

// postJSON is a small helper since transport.Client.PostJSON returns
// the raw response (we want to parse status + body uniformly).
func postJSON(ctx context.Context, c *transport.Client, path string, body []byte) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.PlatformURL+path, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	return c.Do(req)
}
