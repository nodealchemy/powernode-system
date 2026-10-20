// identity.go holds Identity, the Strategy interface, Resolver and
// DefaultResolver's strategy order. The package documentation lives in
// doc.go.

package identity

import (
	"context"
	"errors"
	"fmt"
	"runtime"
	"time"
)

// Identity is what the agent learns at boot. Not every field is required;
// downstream components handle nil/empty fields gracefully.
type Identity struct {
	// InstanceUUID is the canonical NodeInstance.id this agent represents.
	// Sourced from cloud metadata, virtio-fw-cfg, kernel cmdline, or local
	// identity.cfg — whichever strategy hits first.
	InstanceUUID string

	// BootstrapToken is the single-use enrollment token the agent will
	// trade for an mTLS cert at /node_api/enroll. Set when this is the
	// node's first boot.
	BootstrapToken string

	// PlatformURL is the base URL of the Powernode control plane.
	PlatformURL string

	// CABundlePEM is the platform's CA chain in PEM form, embedded into
	// cloud-init / iPXE so the agent can verify the platform's TLS cert
	// before completing enrollment.
	CABundlePEM string

	// CAFingerprint is the pin ("sha256:<hex>") of the platform CA, from a
	// powernode-provision v1 document (always present there) or an optional
	// legacy field. When set it is enforced on the enrolment connection.
	CAFingerprint string

	// Architecture is the node's CPU architecture as the kernel sees it.
	Architecture string

	// CloudProvider is the source that supplied this identity (aws, gcp,
	// azure, digitalocean, libvirt, local). Empty if no cloud detected.
	CloudProvider string

	// DiscoveredAt is when the identity finished resolving. Used for log
	// correlation between agent + control plane.
	DiscoveredAt time.Time
}

// Strategy is a single identity-discovery method. Returns an Identity on
// success; ErrNotFound (or any other error) signals "skip; try the next
// strategy."
type Strategy interface {
	Name() string
	Discover(ctx context.Context) (*Identity, error)
}

// ErrNotFound is the canonical signal a strategy can't supply an identity.
var ErrNotFound = errors.New("identity: not found by this strategy")

// Resolver runs strategies in order and returns the first hit.
type Resolver struct {
	Strategies []Strategy
	Timeout    time.Duration
}

// DefaultResolver returns a resolver pre-loaded with the standard strategies
// in the recommended priority order:
//  1. CmdlineStrategy           — fastest, no network
//  2. FwCfgStrategy             — virtio-fw-cfg (libvirt/QEMU)
//  3. LocalIdentityStrategy     — /run/powernode/identity.cfg (Option 3:
//     NoCloud cicustom-staged enrollment identity, uefi_disk builders)
//  4. MediaScanStrategy         — powernode-provision.cfg on attached drives
//     (USB, cidata/CD-ROM, extra disks; media.go). D10 formalises its place
//     relative to provider metadata and the BOOT identity.cfg.
//  5. ClaimStrategy             — physical disk-image flow (boot partition)
//  6. AWS / GCP / Azure / DO    — cloud metadata (~1-1.5s timeout each)
//  7. LocalIdentityStrategy     — /etc/identity.cfg (legacy fallback)
//
// Cloud strategies are deliberately ordered after the no-network paths so
// a QEMU node booting locally doesn't waste seconds probing cloud
// metadata services that aren't there. ClaimStrategy sits between fw-cfg
// and the cloud probes so a Pi 4 booted from a generic disk image doesn't
// pay 4×1.5s for cloud metadata that isn't there — its BootIdentityStrategy
// helper reads /boot/identity.cfg in <1ms; if absent (cloud VM, no boot
// partition), ClaimStrategy returns ErrNotFound and the chain falls
// through to cloud strategies naturally.
//
// The /run/powernode/identity.cfg strategy sits between fw-cfg and
// ClaimStrategy for the same reason: a pool-provisioned Proxmox uefi_disk
// builder's baked image carries a claim-by-ID /boot/identity.cfg (SERVER=
// set to the CI/claim endpoint), so ClaimStrategy would otherwise win
// first and poll /node_api/claim forever instead of ever reaching the
// real enrollment identity. powernode-cidata-payload.service stages the
// provider's cicustom (NoCloud) identity payload to /run/powernode/
// identity.cfg pre-pivot, Before=powernode-agent.service, whenever the
// PVE connection is API-token-only (fw-cfg's `args` field is root@pam-only
// — see System::Providers::Proxmox::EnrollmentSeed#render_cicustom). If
// that file is absent (no cicustom identity staged — the steady state for
// every other boot path), this instance returns ErrNotFound and the chain
// falls through unchanged, so physical/boot-identity devices see zero
// behavior change.
//
// Plan: docs/plans/wondrous-yawning-anchor.md §4.
func DefaultResolver() *Resolver {
	return &Resolver{
		Strategies: []Strategy{
			&CmdlineStrategy{},
			&FwCfgStrategy{},
			&LocalIdentityStrategy{Path: "/run/powernode/identity.cfg"},
			&MediaScanStrategy{},
			&ClaimStrategy{},
			&CloudStrategy{Client: &AwsMetadataClient{}},
			&CloudStrategy{Client: &GcpMetadataClient{}},
			&CloudStrategy{Client: &AzureMetadataClient{}},
			&CloudStrategy{Client: &DigitalOceanMetadataClient{}},
			// Cloud strategies are added by package init in cloud_*.go files.
			&LocalIdentityStrategy{Path: "/etc/identity.cfg"},
		},
		Timeout: 30 * time.Second,
	}
}

// Resolve runs strategies in order; returns the first non-error Identity.
// If every strategy returns ErrNotFound, returns ErrNotFound (so the caller
// can distinguish from a partial failure). Architecture is filled from
// runtime.GOARCH if no strategy provided one.
func (r *Resolver) Resolve(ctx context.Context) (*Identity, error) {
	if r.Timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, r.Timeout)
		defer cancel()
	}

	var (
		lastErr error
		first   *Identity // first usable identity, by strategy precedence
		pin     string    // first pin seen from ANY source
	)
	for _, s := range r.Strategies {
		if first != nil {
			// A pinless hit was already found: keep scanning ONLY LOCAL sources
			// (files, fw-cfg, cmdline) to collect a pin and let a refused local
			// v1 document stop us. Never run a strategy that blocks or polls
			// (claim) or that goes over the network: unauthenticated cloud
			// metadata (169.254.169.254 over HTTP) is spoofable on L2, so it can
			// neither supply a pin nor veto a local identity (and skipping it
			// avoids seconds of probing on bare metal). The removable-media
			// scan is skipped for the same reason: a stick must never veto a
			// legitimate identity nor attach an attacker-chosen pin to it. A later source never
			// replaces the identity that supplied the key.
			switch s.(type) {
			case *ClaimStrategy, *CloudStrategy, *MediaScanStrategy:
				continue
			}
		}
		id, err := s.Discover(ctx)
		if err != nil {
			if errors.Is(err, ErrProvisionRefused) {
				// TERMINAL: a v1 document / pin was present but invalid. Do
				// not fall through to a weaker source.
				return nil, fmt.Errorf("strategy %s: %w", s.Name(), err)
			}
			if errors.Is(err, ErrNotFound) {
				continue
			}
			// Non-NotFound error: remember + try next strategy.
			lastErr = fmt.Errorf("strategy %s: %w", s.Name(), err)
			continue
		}
		if id == nil || id.InstanceUUID == "" {
			continue
		}
		if pin == "" {
			pin = id.CAFingerprint
		}
		if first == nil {
			first = id
			if pin != "" {
				break // pinned hit: nothing more to learn
			}
		}
	}
	if first != nil {
		if first.CAFingerprint == "" {
			first.CAFingerprint = pin // a pinless source never overrides a pin
		}
		if first.Architecture == "" {
			first.Architecture = runtime.GOARCH
		}
		first.DiscoveredAt = time.Now().UTC()
		return first, nil
	}

	if lastErr != nil {
		return nil, lastErr
	}
	return nil, ErrNotFound
}
