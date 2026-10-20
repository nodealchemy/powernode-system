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
//  1. CmdlineStrategy       - kernel command-line params / PXE single-fetch pickup
//  2. FwCfgStrategy         - QEMU virtio-fw-cfg blobs
//  3. LocalIdentityStrategy - /run/powernode/identity.cfg, the staged NoCloud /
//     config-drive document
//  4. CloudStrategy         - provider metadata user-data (AWS, GCP, Azure,
//     DigitalOcean/OpenStack clients)
//  5. MediaScanStrategy     - powernode-provision.cfg on attached drives
//  6. BootKeyStrategy       - the KEY in /boot/identity.cfg
//  7. ConsolePromptStrategy - masked console prompt (InteractiveResolver only)
//  8. ClaimStrategy         - claim poll, driven by the BOOT SERVER/ID
//
// followed by LocalIdentityStrategy on /etc/identity.cfg, the legacy fallback.
// The first non-empty key wins; a ca_fingerprint from any source is enforced
// on the winner. The comment on DefaultResolver records why this order is
// safe (metadata is unauthenticated) and PROVISION_DOCUMENT.md documents it.
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
