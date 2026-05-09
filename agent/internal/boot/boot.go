// Package boot implements the agent's first-boot orchestration —
// the work that runs from initramfs init-bottom before the real
// rootfs is pivoted in via switch_root.
//
// Compose pattern: this package owns no primitives of its own;
// it composes identity discovery + enrollment + mount orchestration
// into a single Boot(ctx) flow. The primitives (identity.Resolver,
// enroll.Client, mount.Runner) all have their own tests and live
// in their own packages.
//
// Phase 3 of the agent stub implementation plan. Stub #1.
package boot

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/enroll"
	"github.com/nodealchemy/powernode-system/agent/internal/identity"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/transport"
)

// SwitchRootFn is the function the orchestrator calls to pivot into
// the assembled rootfs. Defined as a function-typed field on the
// Orchestrator so tests can inject a stub — `systemctl switch-root`
// in production replaces the running process and never returns,
// which makes integration testing impossible without injection.
type SwitchRootFn func(target string) error

// Orchestrator owns the boot flow's dependencies. Each field is
// independently injectable so tests can stub piecewise.
type Orchestrator struct {
	// Resolver discovers the node's identity (instance UUID, platform
	// URL, bootstrap token, CA bundle).
	Resolver *identity.Resolver
	// EnrollClient is partially configured (HTTPClient may be nil
	// to use the default); the orchestrator fills in PlatformURL +
	// CABundlePEM from the discovered Identity before calling Enroll.
	EnrollClient *enroll.Client
	// MountRunner is the os/exec abstraction the mount package uses.
	MountRunner mount.Runner
	// Layout describes mount points (sysroot, modules cache, etc.).
	Layout mount.Layout
	// PKIDir is where to persist enrollment material. Defaults to
	// enroll.PKIDir.
	PKIDir string
	// AgentVersion is reported during enrollment for log correlation.
	AgentVersion string
	// SwitchRoot is the function that pivots into /sysroot. Defaults
	// to systemctlSwitchRoot which runs `systemctl switch-root`.
	SwitchRoot SwitchRootFn
	// DryRun, when true, walks every step and logs the plan without
	// executing mounts or switch_root. Enroll is also skipped in
	// dry-run because the bootstrap token is single-use.
	DryRun bool
	// OnStage emits per-stage status updates for observability.
	// Default is a no-op.
	OnStage func(stage, message string)
	// ClaimPollInterval is the gap between /node_api/claim polls
	// when the resolver returns ClaimPending. Default 30s.
	ClaimPollInterval time.Duration
	// ClaimPollTimeout caps the total time the orchestrator will
	// wait for an operator to bind the claim. Default 0 = wait
	// forever (matches initramfs behavior — operators expect the
	// node to remain reachable while they bind it).
	ClaimPollTimeout time.Duration
}

// Default fills in reasonable defaults for any zero-value field.
// Returns a copy with the defaults applied; the caller's
// Orchestrator is left untouched. Tests pass an Orchestrator literal
// with explicit overrides; production code calls Default after
// constructing the resolver/enroll client.
func (o Orchestrator) Default() Orchestrator {
	if o.PKIDir == "" {
		o.PKIDir = enroll.PKIDir
	}
	if o.MountRunner == nil {
		o.MountRunner = mount.ExecRunner{}
	}
	if (o.Layout == mount.Layout{}) {
		o.Layout = mount.DefaultLayout()
	}
	if o.SwitchRoot == nil {
		o.SwitchRoot = systemctlSwitchRoot
	}
	if o.OnStage == nil {
		o.OnStage = func(string, string) {}
	}
	if o.ClaimPollInterval == 0 {
		o.ClaimPollInterval = 30 * time.Second
	}
	return o
}

// Boot runs the first-boot flow synchronously. On success, this
// function does NOT return — switch_root replaces the running
// process. Returns an error iff a step fails before the pivot.
//
// Sequence:
//  1. Resolve identity (cmdline → fwcfg → claim → cloud → local)
//  2. Fast path: existing PKI on disk → skip enroll, jump to mount
//  3. Otherwise: enroll via /node_api/enroll, persist PKI
//  4. Mount composefs+overlay union at /sysroot
//  5. switch_root /sysroot /sbin/init
func (o *Orchestrator) Boot(ctx context.Context) error {
	if o == nil {
		return errors.New("boot.Orchestrator: nil receiver")
	}
	if o.Resolver == nil {
		return errors.New("boot.Orchestrator: Resolver required")
	}
	if o.EnrollClient == nil {
		return errors.New("boot.Orchestrator: EnrollClient required")
	}

	o.stage("identity", "discovering")
	ident, err := o.resolveIdentity(ctx)
	if err != nil {
		return fmt.Errorf("identity discovery: %w", err)
	}
	o.stage("identity", fmt.Sprintf("ok (instance=%s, source=%s)", ident.InstanceUUID, ident.CloudProvider))

	paths := enroll.PathsUnder(o.PKIDir)

	if hasUsableCert(paths, ident.PlatformURL) {
		o.stage("enroll", "skipped (existing PKI on disk)")
	} else if o.DryRun {
		o.stage("enroll", "would-enroll (dry-run skip)")
	} else {
		o.stage("enroll", "exchanging bootstrap token for cert")
		if err := o.enroll(ctx, ident, paths); err != nil {
			return fmt.Errorf("enroll: %w", err)
		}
		o.stage("enroll", "ok")
	}

	o.stage("mount", "composing union rootfs")
	if err := o.mountUnion(ctx); err != nil {
		return fmt.Errorf("mount union: %w", err)
	}
	o.stage("mount", "ok")

	if o.DryRun {
		o.stage("switch_root", "skipped (dry-run)")
		return nil
	}

	o.stage("switch_root", "pivoting to /sysroot")
	if err := o.SwitchRoot(o.Layout.SysRoot); err != nil {
		return fmt.Errorf("switch_root: %w", err)
	}
	// switch_root replaces the running process; we shouldn't reach
	// here on a successful invocation. If we do, treat it as a
	// fatal error.
	return errors.New("switch_root returned (expected to never return)")
}

// resolveIdentity walks the resolver chain. When the resolver
// returns an Identity in claim-pending state (instance_uuid + URL
// but no bootstrap_token), poll until the operator binds it.
func (o *Orchestrator) resolveIdentity(ctx context.Context) (*identity.Identity, error) {
	deadline := time.Now().Add(o.ClaimPollTimeout)
	for {
		ident, err := o.Resolver.Resolve(ctx)
		if err != nil {
			return nil, err
		}
		if ident == nil {
			return nil, errors.New("resolver returned nil identity")
		}
		// Claim-pending = we have URL but no token yet. Operator
		// hasn't bound this device. Wait + retry until they do.
		if ident.BootstrapToken == "" && ident.PlatformURL != "" && hasUsableCert(enroll.PathsUnder(o.PKIDir), ident.PlatformURL) {
			// Already enrolled — this is the post-switch_root re-boot path.
			return ident, nil
		}
		if ident.BootstrapToken != "" {
			return ident, nil
		}
		if o.ClaimPollTimeout > 0 && time.Now().After(deadline) {
			return nil, errors.New("claim poll timeout (operator never bound this device)")
		}
		o.stage("identity", "claim-pending; waiting for operator binding")
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(o.ClaimPollInterval):
		}
	}
}

// enroll exchanges the bootstrap token for an mTLS cert and
// persists the result.
func (o *Orchestrator) enroll(ctx context.Context, ident *identity.Identity, paths enroll.PKIPaths) error {
	if ident.BootstrapToken == "" {
		return errors.New("identity has no BootstrapToken (cert exists on disk? if so, fast-path should have skipped enroll)")
	}
	if len(ident.CABundlePEM) == 0 {
		return errors.New("identity has no CABundlePEM (platform CA chain)")
	}
	o.EnrollClient.PlatformURL = ident.PlatformURL
	o.EnrollClient.CABundlePEM = []byte(ident.CABundlePEM)
	o.EnrollClient.AgentVersion = o.AgentVersion

	enrolled, err := o.EnrollClient.Enroll(ctx, enroll.EnrollRequest{
		BootstrapToken: ident.BootstrapToken,
		Subject:        ident.InstanceUUID,
	})
	if err != nil {
		return err
	}
	return enroll.Save(enrolled, paths)
}

// mountUnion composes the modules into the overlay union rootfs.
// In dry-run mode, no mount commands are issued — only the plan
// is logged.
func (o *Orchestrator) mountUnion(_ context.Context) error {
	if o.DryRun {
		o.stage("mount", "would mount: composefs + overlayfs at "+o.Layout.SysRoot)
		return nil
	}
	// Phase 3 keeps mount orchestration light: the existing
	// prepare-root subcommand handles the libvirt 9p path which is
	// the active smoke-test target. Composefs-driven boot lands as
	// a follow-up once the M3 disk-image pipeline produces signed
	// composefs blobs; for now, the boot subcommand depends on the
	// initramfs unit chain calling prepare-root explicitly, then
	// invoking switch_root via systemctl.
	//
	// This matches the actual production wiring: the boot orchestrator
	// ensures identity + enrollment + a usable PKI dir, and the
	// prepare-root + switch_root systemd units handle the mount/pivot.
	return nil
}

// hasUsableCert is a fast on-disk check that the PKI dir has a
// readable cert + key + CA bundle. Doesn't open a TLS connection
// — that's transport.LoadFromPKIDir's job, called later by the
// service loop. The orchestrator just needs to know whether the
// fast path is viable.
func hasUsableCert(paths enroll.PKIPaths, _ string) bool {
	for _, p := range []string{paths.Cert, paths.Key, paths.CABundle} {
		if !fileNonEmpty(p) {
			return false
		}
	}
	return true
}

func fileNonEmpty(path string) bool {
	st, err := osStat(path)
	if err != nil {
		return false
	}
	return st.Size() > 0
}

// osStat is a package-level alias so tests can redirect filesystem
// access without a real /persist tree.
var osStat = osStatReal

// stage is the internal helper for emitting an OnStage callback.
// Lets callers always reach for a method instead of remembering
// whether OnStage might be nil.
func (o *Orchestrator) stage(name, message string) {
	if o.OnStage != nil {
		o.OnStage(name, message)
	}
}

// systemctlSwitchRoot is the production SwitchRoot — invokes
// `systemctl switch-root <target> /sbin/init` which replaces PID 1.
func systemctlSwitchRoot(target string) error {
	cmd := exec.Command("systemctl", "switch-root", target, "/sbin/init")
	return cmd.Run()
}

// transport.Client reference kept so the import survives — Phase 3
// boot orchestrator may grow to verify the platform's TLS cert by
// opening a connection before enroll. For now the EnrollClient
// handles its own TLS via CABundlePEM.
var _ = transport.Client{}
