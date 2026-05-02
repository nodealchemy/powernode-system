// Package identity discovers a node's identity via multiple strategies
// (DMI/SMBIOS, cloud metadata services, virtio-fw-cfg, kernel cmdline,
// local boot device). The strategies are tried in priority order and the
// first one that yields a non-empty result wins.
//
// Reference: Golden Eclipse plan M2 capabilities — multi-cloud metadata
// discovery; legacy ~/Drive/Projects/powernode-bootstrap/scripts/ipn_initialize
// (ipn_init_discover + ipn_init_identity steps).
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
//  3. AWS / GCP / Azure / DO    — cloud metadata (~1-1.5s timeout each)
//  4. LocalIdentityStrategy     — /etc/identity.cfg (legacy fallback)
//
// Cloud strategies are deliberately ordered after the no-network paths so
// a QEMU node booting locally doesn't waste seconds probing cloud
// metadata services that aren't there.
func DefaultResolver() *Resolver {
	return &Resolver{
		Strategies: []Strategy{
			&CmdlineStrategy{},
			&FwCfgStrategy{},
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

	var lastErr error
	for _, s := range r.Strategies {
		id, err := s.Discover(ctx)
		if err != nil {
			if errors.Is(err, ErrNotFound) {
				continue
			}
			// Non-NotFound error: log + try next strategy.
			lastErr = fmt.Errorf("strategy %s: %w", s.Name(), err)
			continue
		}
		if id == nil || id.InstanceUUID == "" {
			continue
		}
		if id.Architecture == "" {
			id.Architecture = runtime.GOARCH
		}
		id.DiscoveredAt = time.Now().UTC()
		return id, nil
	}

	if lastErr != nil {
		return nil, lastErr
	}
	return nil, ErrNotFound
}
