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

	// Purpose is the v1 document's purpose field ("" for legacy sources). The
	// console prompt stages its document with ConsolePurpose.
	Purpose string

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
	// Timeout bounds the non-interactive strategies. It does NOT apply to the
	// console prompt, which has its own timeout (default 60s).
	Timeout time.Duration
	// Interactive lets ConsolePromptStrategy prompt on /dev/console. Only the
	// boot and service paths set it (InteractiveResolver); CLI commands,
	// soft_recompose and prepare-root never prompt.
	Interactive bool
}

// InteractiveResolver is DefaultResolver with the console prompt enabled, for
// the boot and service enrolment paths only.
func InteractiveResolver() *Resolver {
	r := DefaultResolver()
	r.Interactive = true
	return r
}

// DefaultResolver returns a resolver pre-loaded with the standard strategies in
// the operator's fixed precedence order (design memory:image-distribution-model;
// documented for operators in extensions/system/docs/PROVISION_DOCUMENT.md):
//
//  1. CmdlineStrategy        - kernel cmdline / PXE single-fetch pickup
//  2. FwCfgStrategy          - virtio fw-cfg (libvirt/QEMU)
//  3. LocalIdentityStrategy  - /run/powernode/identity.cfg, the NoCloud /
//     config-drive document staged pre-pivot by powernode-cidata-payload.service
//  4. CloudStrategy x4       - provider metadata user-data: AWS, GCP, Azure,
//     OpenStack/DigitalOcean (~1-1.5s probe timeout each)
//  5. MediaScanStrategy      - powernode-provision.cfg on attached drives
//  6. BootKeyStrategy        - the KEY of /boot/identity.cfg
//  7. ConsolePromptStrategy  - masked /dev/console prompt (InteractiveResolver
//     only; initramfs)
//  8. ClaimStrategy          - claim poll with the BOOT SERVER/ID (blocks)
//     then, outside the eight, the legacy /etc/identity.cfg fallback.
//
// The first non-empty key wins and a later source never overrides it. A
// ca_fingerprint from ANY source is enforced on whichever source wins; the
// resolver collects it from the LOCAL sources (see Resolve).
//
// Why the order is safe despite metadata ranking above media and BOOT:
//
//   - Metadata is unauthenticated (169.254.169.254 over HTTP, spoofable on
//     L2). It is only ever consulted while no key has been found, so it never
//     overrides cmdline / fw-cfg / the staged document. When it does win over
//     media or BOOT, the BOOT pin is still collected and REPLACES any pin the
//     metadata document carries, so a spoofed server cannot attach its own CA
//     to a pinned device (the enrolment then fails closed).
//   - A v1 refusal from metadata stays terminal, with one exception: the BOOT
//     key (the only local source that used to run before the cloud probes)
//     is still tried, so a spoofed refusal cannot veto a local identity.
//   - Media sits behind metadata and is never run once a key exists, so a
//     stick cannot veto an identity or attach a pin to it.
//   - The console prompt is interactive-resolver only and runs after every
//     non-blocking source; the claim poll blocks, so it is last.
//
// Cost: bare-metal nodes with no earlier key now pay the cloud probes (up to
// ~6s on a non-cloud network) before the media scan, BOOT key and prompt.
func DefaultResolver() *Resolver {
	return &Resolver{
		Strategies: []Strategy{
			&CmdlineStrategy{},
			&FwCfgStrategy{},
			&LocalIdentityStrategy{Path: "/run/powernode/identity.cfg"},
			&CloudStrategy{Client: &AwsMetadataClient{}},
			&CloudStrategy{Client: &GcpMetadataClient{}},
			&CloudStrategy{Client: &AzureMetadataClient{}},
			&CloudStrategy{Client: &DigitalOceanMetadataClient{}},
			&MediaScanStrategy{},
			&BootKeyStrategy{},
			&ConsolePromptStrategy{Timeout: consolePromptTimeout(DefaultCmdlinePath)},
			&ClaimStrategy{},
			&LocalIdentityStrategy{Path: "/etc/identity.cfg"},
		},
		Timeout: 30 * time.Second,
	}
}

// pinSource is implemented by a LOCAL strategy that can report a
// ca_fingerprint without supplying the key (BootKeyStrategy).
type pinSource interface {
	DiscoverPin(ctx context.Context) (string, error)
}

// Resolve runs strategies in order; returns the first non-error Identity.
// If every strategy returns ErrNotFound, returns ErrNotFound (so the caller
// can distinguish from a partial failure). Architecture is filled from
// runtime.GOARCH if no strategy provided one.
func (r *Resolver) Resolve(ctx context.Context) (*Identity, error) {
	parent := ctx // the console prompt honours cancellation but not Timeout
	if r.Timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, r.Timeout)
		defer cancel()
	}

	var (
		lastErr  error
		first    *Identity // first usable identity, by strategy precedence
		firstNet bool      // first came from provider metadata (self-asserted pin)
		pin      string    // first pin seen from a LOCAL source
		refused  error     // a cloud v1 refusal: terminal unless BOOT supplies a key
	)
	for _, s := range r.Strategies {
		_, isCloud := s.(*CloudStrategy)
		_, isBootKey := s.(*BootKeyStrategy)
		if refused != nil && !isBootKey {
			// Terminal refusal: only the BOOT key may still rescue it (it ran
			// before the cloud probes in the old order, and a spoofed
			// metadata server must not veto a local identity). Nothing weaker.
			continue
		}
		if first != nil {
			// A hit was already found: keep scanning ONLY LOCAL sources (files,
			// fw-cfg, cmdline) to collect a pin and let a refused local v1
			// document stop us. Never run a strategy that blocks or polls
			// (claim) or that goes over the network: unauthenticated cloud
			// metadata (169.254.169.254 over HTTP) is spoofable on L2, so it can
			// neither supply a pin nor veto a local identity (and skipping it
			// avoids seconds of probing on bare metal). The removable-media
			// scan is skipped for the same reason: a stick must never veto a
			// legitimate identity nor attach an attacker-chosen pin to it. A later source never
			// replaces the identity that supplied the key.
			switch s.(type) {
			case *ClaimStrategy, *CloudStrategy, *MediaScanStrategy, *ConsolePromptStrategy:
				continue
			}
			if ps, ok := s.(pinSource); ok {
				p, err := ps.DiscoverPin(ctx)
				if err != nil {
					if errors.Is(err, ErrProvisionRefused) {
						return nil, fmt.Errorf("strategy %s: %w", s.Name(), err)
					}
					continue
				}
				if pin == "" {
					pin = p
				}
				continue
			}
		}
		sctx := ctx
		if _, ok := s.(*ConsolePromptStrategy); ok {
			if !r.Interactive {
				continue
			}
			sctx = parent
		}
		id, err := s.Discover(sctx)
		if err != nil {
			if errors.Is(err, context.Canceled) && parent.Err() != nil {
				return nil, err
			}
			if errors.Is(err, ErrProvisionRefused) {
				// TERMINAL: a v1 document / pin was present but invalid. Do
				// not fall through to a weaker source.
				werr := fmt.Errorf("strategy %s: %w", s.Name(), err)
				if isCloud && first == nil {
					// Unauthenticated metadata must not veto a local BOOT key:
					// remember the refusal; it is returned if no BOOT key shows.
					refused = werr
					continue
				}
				return nil, werr
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
		if !isCloud && pin == "" {
			pin = id.CAFingerprint
		}
		if first == nil {
			first = id
			firstNet = isCloud
			refused = nil
			if pin != "" && !firstNet {
				break // pinned local hit: nothing more to learn
			}
		}
	}
	if first == nil && refused != nil {
		return nil, refused
	}
	if first != nil {
		// A local pin is authoritative: it replaces a pin the (spoofable)
		// metadata document carries; a pinless source never overrides a pin.
		if pin != "" && (first.CAFingerprint == "" || firstNet) {
			first.CAFingerprint = pin
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
