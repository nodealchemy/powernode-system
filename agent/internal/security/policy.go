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

	// Privileged opt-in. Defaults to false. Privileged modules MUST be
	// approved out-of-band by an operator before attach.
	Privileged bool

	// UserNamespace: map module processes into a user namespace where
	// possible. Defaults to true. Some workloads (raw socket access) need
	// the host namespace.
	UserNamespace bool
}

// Apply runs each enforcement step against the system. The order matters:
//  1. SELinux/AppArmor profile loaded first (kernel-enforced before processes spawn)
//  2. Seccomp filter applied
//  3. Capabilities dropped
//  4. Egress allowlist installed (nftables)
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
		// The module's manifest must have been operator-approved before reaching
		// this code; we just install egress + return.
		return p.applyEgress(ctx, runner)
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
	if err := p.applyEgress(ctx, runner); err != nil {
		return fmt.Errorf("apply egress: %w", err)
	}
	return nil
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

func (p *Policy) applyEgress(ctx context.Context, runner mount.Runner) error {
	return ApplyEgressAllowlist(ctx, runner, p.EgressAllow)
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
