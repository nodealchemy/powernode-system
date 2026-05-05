// Package identity discovers the agent's identity at boot — what node am I,
// how do I find the platform, what bootstrap token (if any) do I have.
//
// Identity is the prerequisite for enrollment: a strategy returns a partial
// or complete Identity, which the boot subcommand uses to call
// internal/enroll for the CSR → mTLS cert exchange.
//
// # Strategies
//
// Per project_local_qemu_provider memory + Golden Eclipse plan M2.A:
//
//   - LocalIdentityStrategy   — file at /boot/powernode/identity.cfg (KEY=VALUE)
//   - CmdlineIdentityStrategy — kernel command line params (powernode.id=, etc.)
//   - VirtioFwCfgStrategy     — libvirt fw-cfg blob (the LocalQemuProvider path)
//   - BootIdentityStrategy    — pre-flash placeholder (claim flow target)
//   - AwsIdentityStrategy     — IMDSv2 instance metadata (M2.B planned)
//   - GcpIdentityStrategy     — GCE metadata server (M2.B planned)
//   - AzureIdentityStrategy   — IMDS endpoint (M2.B planned)
//   - DigitalOceanStrategy    — DO metadata (M2.B planned)
//   - ClaimStrategy           — pre-claimed device polls /node_api/claim until
//                                an operator binds it to an account
//
// The boot subcommand iterates strategies in priority order; first one that
// returns a non-error result wins.
//
// # Key types
//
//	Identity        — { ID, BootstrapToken, PlatformURL, CABundlePEM }
//	Strategy        — interface { Discover(ctx) (Identity, error) }
//	Resolver        — picks a strategy + caches the result
//
// Server-side counterpart: extensions/system/server/app/services/system/
// node_enrollment_service.rb handles the CSR side of the handshake.
package identity
