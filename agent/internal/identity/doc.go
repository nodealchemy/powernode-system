// Package identity discovers the agent's identity at boot: which NodeInstance
// this is, where the platform is, and what bootstrap token (if any) it holds.
//
// Identity is the prerequisite for enrollment: a strategy returns a partial
// or complete Identity, which the boot subcommand uses to call
// internal/enroll for the CSR → mTLS cert exchange.
//
// # Strategies
//
// DefaultResolver tries these in order and the first to return an identity
// wins; a strategy with nothing to offer returns ErrNotFound:
//
//  1. CmdlineStrategy       — powernode.<key>=<value> kernel command-line params
//  2. FwCfgStrategy         — QEMU virtio-fw-cfg blobs (libvirt/QEMU providers)
//  3. LocalIdentityStrategy — /run/powernode/identity.cfg, the NoCloud cicustom
//     identity staged pre-pivot on Proxmox uefi_disk builders
//  4. ClaimStrategy         — a device flashed from a generic disk image: its
//     BootIdentityStrategy reads /boot/identity.cfg, and without a bootstrap
//     token it polls /api/v1/system/node_api/claim until an operator confirms
//  5. CloudStrategy         — cloud metadata, once each through
//     AwsMetadataClient, GcpMetadataClient, AzureMetadataClient and
//     DigitalOceanMetadataClient
//  6. LocalIdentityStrategy — /etc/identity.cfg, the legacy bare-metal fallback
//
// The no-network strategies run before the cloud probes so a local or
// physical node does not wait on metadata services that are not there. The
// comment on DefaultResolver records why each one sits where it does.
//
// # Key types
//
//	Identity — InstanceUUID, BootstrapToken, PlatformURL, CABundlePEM,
//	           Architecture, CloudProvider, DiscoveredAt
//	Strategy — interface { Name() string; Discover(ctx) (*Identity, error) }
//	Resolver — runs its Strategies in order under one overall Timeout
//
// Server-side counterpart: extensions/system/server/app/services/system/
// node_enrollment_service.rb handles the CSR side of the handshake.
package identity
