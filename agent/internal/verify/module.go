package verify

import (
	"context"
	"errors"
	"fmt"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// Module signature verification modes. The ladder encodes blast radius: each
// rung past off adds a site whose refusal has worse consequences, and the
// boot composer — where a refused mount is an UNBOOTABLE NODE — is last.
//
//	off      no verification anywhere. THE DEFAULT. AlwaysOK at every site,
//	         no trust anchor required, no network fetch, no behaviour change.
//	audit    verify everywhere, refuse nowhere. Every would-be refusal is
//	         reported through the site's error hook. This is the MEASURE
//	         step: run it fleet-wide before any enforcing rung.
//	runtime  enforce on the 60s service loop and the attach/update/sync/detach
//	         CLIs — the paths where a refused mount is recoverable — and
//	         audit on the boot composer.
//	all      enforce everywhere, boot composer included.
const (
	ModeOff     = "off"
	ModeAudit   = "audit"
	ModeRuntime = "runtime"
	ModeAll     = "all"
)

// Site names a module-mount construction site by blast radius. It decides
// which rung of the mode ladder enforces there.
type Site string

const (
	// SiteService is the long-lived 60s reconcile loop (runtime/service.go).
	// A refused mount here is reported every tick and recovers when the
	// platform publishes a signed artifact.
	SiteService Site = "service"
	// SiteCLI is BuildReconciler for attach/update/sync/detach. A refused
	// mount is an operator-visible command failure.
	SiteCLI Site = "cli"
	// SiteBoot is NewPivotComposerAt, the direct_kernel boot composer
	// (bootCmd, prepare-root, soft-recompose). A refused mount here is an
	// unbootable node, on nodes that typically cannot be re-provisioned.
	SiteBoot Site = "boot"
)

// ModuleSigningConfig is the operator's module-signature policy for one
// node. Resolved by runtime.LoadModuleSigningConfig from flags / env /
// the persisted conf file; the zero value is ModeOff.
type ModuleSigningConfig struct {
	// Mode is one of the Mode* constants. Empty means ModeOff.
	Mode string
	// KeyPaths are the trusted cosign PUBLIC keys (PEM files). Either pinned
	// by the operator (strongest: the anchor does not travel the channel it
	// guards) or the cached copy of the platform's trusted-key list fetched
	// by the runtime package (bounded: anyone who can impersonate the
	// platform can supply both the blob and the key it verifies under —
	// the same bound the boot path's inline cosign_public_key has).
	KeyPaths []string
}

// Active reports whether any verification happens at all.
func (c ModuleSigningConfig) Active() bool {
	return c.mode() != ModeOff
}

// Enforces reports whether a failed verification REFUSES the mount at site.
// False for audit (report only) and for the boot composer under runtime.
func (c ModuleSigningConfig) Enforces(site Site) bool {
	switch c.mode() {
	case ModeAll:
		return true
	case ModeRuntime:
		return site != SiteBoot
	default:
		return false
	}
}

func (c ModuleSigningConfig) mode() string {
	if c.Mode == "" {
		return ModeOff
	}
	return c.Mode
}

// Validate rejects a mode outside the ladder. An unknown value is refused
// rather than coerced in either direction: "enforce" silently meaning off
// would be a bypass, silently meaning all would be an outage.
func (c ModuleSigningConfig) Validate() error {
	switch c.mode() {
	case ModeOff, ModeAudit, ModeRuntime, ModeAll:
		return nil
	}
	return fmt.Errorf("module signing mode %q: want one of off, audit, runtime, all", c.Mode)
}

// NewModuleVerifier is THE constructor every module-mount site — and the
// operator `powernode-agent verify --key` CLI — obtains its Verifier from,
// so that what the CLI green-lights is exactly what the node would accept.
//
// ModeOff (the default) returns AlwaysOK with no further checks. Every other
// mode requires at least one trusted key and returns a static-key
// CosignVerifier, wrapped in AuditVerifier when the mode does not enforce at
// this site. report receives audit findings; nil is tolerated.
func NewModuleVerifier(cfg ModuleSigningConfig, site Site, runner mount.Runner, report func(stage string, err error)) (Verifier, error) {
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	if !cfg.Active() {
		return AlwaysOK{}, nil
	}
	keys := make([]string, 0, len(cfg.KeyPaths))
	for _, k := range cfg.KeyPaths {
		if k != "" {
			keys = append(keys, k)
		}
	}
	if len(keys) == 0 {
		return nil, errors.New("module signing mode " + cfg.mode() + " configured with no trusted public key: pin one (KEYS= in the module-signing conf, --module-signing-key) or let the runtime fetch the platform's list")
	}
	if runner == nil {
		runner = mount.ExecRunner{}
	}
	real := &CosignVerifier{Runner: runner, KeyPaths: keys}
	if cfg.Enforces(site) {
		return real, nil
	}
	if report == nil {
		report = func(string, error) {}
	}
	return AuditVerifier{Inner: real, Report: report}, nil
}

// AuditVerifier runs Inner and reports — but never returns — its failures.
// It is the measurement instrument for the audit rung and for the boot
// composer under runtime: the operator sees, per node and per module, what
// an enforcing verifier WOULD have refused, before deciding to enforce.
type AuditVerifier struct {
	Inner  Verifier
	Report func(stage string, err error)
}

// VerifyBlob always returns nil; a failure from Inner is passed to Report
// under the stage "verify:module_signature_audit" with the blob path.
func (a AuditVerifier) VerifyBlob(ctx context.Context, blobPath, bundlePath string) error {
	if a.Inner == nil {
		return nil
	}
	if err := a.Inner.VerifyBlob(ctx, blobPath, bundlePath); err != nil && a.Report != nil {
		a.Report("verify:module_signature_audit", fmt.Errorf("would refuse %s: %w", blobPath, err))
	}
	return nil
}
