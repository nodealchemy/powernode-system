// Package security applies a module's manifest.yaml `security:` block on
// the running node: capability dropping, SELinux/AppArmor profile loading,
// seccomp filter compilation, egress allowlist enforcement.
//
// Each operation uses the mount.Runner abstraction so unit tests can verify
// command shape without root or kernel features.
//
// Reference: Golden Eclipse plan Security Architecture (Module-Level Security);
// module manifest.yaml security block schema.
package security

import (
	"context"
	"errors"
	"fmt"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// Policy is the module-level security policy declared in manifest.yaml#security.
// Applied at module attach time by Apply.
type Policy struct {
	// Capabilities the module's processes may retain. Empty = drop all
	// (except whatever the kernel keeps for basic IO).
	Capabilities []string

	// Path to a SELinux policy module (.pp file) to load before the module
	// processes run. Empty = no SELinux profile applied.
	SELinuxProfile string

	// Path to an AppArmor profile to load. Empty = no AppArmor profile.
	AppArmorProfile string

	// Path to a seccomp filter JSON file (libseccomp / docker-seccomp shape).
	SeccompProfile string

	// Egress-allowed destinations: ["host:port", "host"]. Default-deny is
	// applied to everything else via nftables. Empty list = block all egress.
	EgressAllow []string

	// EgressDeclared is true when the module's manifest.yaml explicitly
	// contains a security.egress_allow key — even an empty list. It
	// distinguishes "this module has an opinion on egress" (possibly a
	// deliberate empty/restrictive one) from "this module never mentioned
	// egress at all". Only modules with EgressDeclared=true participate in
	// UnionEgressPolicy; a module that never declares the key contributes
	// nothing and does not, by its mere presence, trigger node-wide
	// enforcement.
	EgressDeclared bool

	// Privileged opt-in. Defaults to false. Privileged modules MUST be
	// approved out-of-band by an operator before attach.
	Privileged bool

	// UserNamespace: map module processes into a user namespace where
	// possible. Defaults to true. Some workloads (raw socket access) need
	// the host namespace.
	UserNamespace bool
}

// Apply runs each PER-MODULE enforcement step against the system. The
// order matters:
//  1. SELinux/AppArmor profile loaded first (kernel-enforced before processes spawn)
//  2. Seccomp filter applied
//  3. Capabilities dropped
//
// Egress is deliberately NOT applied here. Unlike capabilities/seccomp,
// which enforce per-UNIT via systemd drop-ins, egress is one nftables
// OUTPUT chain shared by the WHOLE NODE — applying it per-module (as this
// method used to) means whichever module's Apply happens to run last wins
// and silently clobbers every sibling module's policy, including a more
// permissive one (e.g. a dev-cell module's declared "unrestricted egress"
// getting overwritten by a stricter sibling that reconciles afterward).
// The node-wide effective policy must instead be computed ONCE per
// reconcile tick as the UNION of every currently-attached module's
// declared policy — see UnionEgressPolicy, called by the reconciler
// alongside its identity/sudoers union step, never from here.
//
// On any failure mid-way, returns the error without rolling back; the
// caller (mount package's MountModule path) MUST refuse to start the
// module's services if Apply returns non-nil.
func (p *Policy) Apply(ctx context.Context, runner mount.Runner) error {
	if p == nil {
		return nil // empty policy = no enforcement (caller's choice)
	}

	if p.Privileged {
		// Privileged modules skip MAC profiles + capability drops by design.
		// The module's manifest must have been operator-approved before
		// reaching this code. Egress (if declared) still flows through the
		// node-wide UnionEgressPolicy step like any other module.
		return nil
	}

	if err := p.loadMACProfile(ctx, runner); err != nil {
		return fmt.Errorf("load MAC profile: %w", err)
	}
	if err := p.applySeccomp(ctx, runner); err != nil {
		return fmt.Errorf("apply seccomp: %w", err)
	}
	if err := p.dropCapabilities(ctx, runner); err != nil {
		return fmt.Errorf("drop capabilities: %w", err)
	}
	return nil
}

// UnionEgressPolicy computes the NODE-WIDE effective egress allowlist from
// every currently-attached module's individual Policy. See Apply's doc
// comment for why this must be a union computed once per reconcile tick
// rather than each module enforcing its own view of the shared chain.
//
// A module contributes to (and triggers) enforcement only when
// EgressDeclared is true; modules that never mention egress_allow at all
// are silently excluded rather than treated as "wants full block" — the
// old per-module semantics conflated "no opinion" with "explicit empty
// allowlist", which would have made ANY module lacking a security block
// force-enable a node-wide default-deny chain.
//
// Returns (allowlist, enforced). enforced is false when no attached module
// declared an egress policy this tick — the caller should then tear down
// any stale enforcement chain (RemoveEgressAllowlist) rather than call
// ApplyEgressAllowlistWithProtected with an empty list, which would
// install a full-block chain nobody actually asked for.
func UnionEgressPolicy(policies []*Policy) (allowlist []string, enforced bool) {
	seen := make(map[string]bool)
	for _, p := range policies {
		if p == nil || !p.EgressDeclared {
			continue
		}
		enforced = true
		for _, entry := range p.EgressAllow {
			if entry == "" || seen[entry] {
				continue
			}
			seen[entry] = true
			allowlist = append(allowlist, entry)
		}
	}
	return allowlist, enforced
}

// loadMACProfile loads SELinux or AppArmor profile, whichever is set.
// Both can be set if the host runs both LSMs simultaneously (rare); they
// load independently.
func (p *Policy) loadMACProfile(ctx context.Context, runner mount.Runner) error {
	if p.SELinuxProfile != "" {
		if err := LoadSELinuxProfile(ctx, runner, p.SELinuxProfile); err != nil {
			return err
		}
	}
	if p.AppArmorProfile != "" {
		if err := LoadAppArmorProfile(ctx, runner, p.AppArmorProfile); err != nil {
			return err
		}
	}
	return nil
}

func (p *Policy) applySeccomp(ctx context.Context, runner mount.Runner) error {
	if p.SeccompProfile == "" {
		return nil
	}
	return ApplySeccompProfile(ctx, runner, p.SeccompProfile)
}

func (p *Policy) dropCapabilities(ctx context.Context, runner mount.Runner) error {
	return DropCapabilitiesExcept(ctx, runner, p.Capabilities)
}

// Validate sanity-checks the policy fields before Apply runs. Returns the
// list of issues; nil means the policy is OK to apply.
func (p *Policy) Validate() []error {
	if p == nil {
		return nil
	}
	var errs []error
	for _, cap := range p.Capabilities {
		if !isValidCapName(cap) {
			errs = append(errs, fmt.Errorf("unknown capability: %q", cap))
		}
	}
	if p.Privileged && (len(p.Capabilities) > 0 || p.SELinuxProfile != "" || p.AppArmorProfile != "" || p.SeccompProfile != "") {
		errs = append(errs, errors.New("privileged=true is incompatible with explicit MAC/seccomp/capability policy — pick one"))
	}
	return errs
}
