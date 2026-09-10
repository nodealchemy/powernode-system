// Package runtime implements the long-lived agent service loop: heartbeats,
// task leases, cert rotation, module reconcile, and dockerd/k3sd handshakes.
//
// Invoked by `powernode-agent service`. Stays running for the lifetime of
// the NodeInstance; restarts automatically via systemd unit on failure.
//
// # Tick structure
//
// Per-tick (default interval 30s, configurable via Config.HeartbeatInterval):
//
//  1. POST /node_api/status with heartbeat (uptime, version, last result)
//  2. POST /node_api/modules → reconcile assignments → mount erofs + overlay union
//  3. dockerd.Manager.Tick (if docker-engine module assigned)
//  4. k3sd.Manager.Tick (if k3s-server / k3s-agent module assigned)
//  5. sdwan.Manager.Tick — apply wg + nft + FRR config from platform
//  6. transport.Mtls.RotateIfNearExpiry — auto-renews cert at 30 days
//  7. Sleep until next interval
//
// # Key types
//
//	Config       — { PlatformURL, AgentVersion, HeartbeatInterval, PKIDir, ... }
//	Service      — orchestrates the tick loop; New(cfg) then Run(ctx), which
//	               returns when the caller's context is cancelled
//	Reconciler   — the module reconcile pass, configured by ReconcilerConfig
//	               and reporting SyncResult
//	Heartbeater  — the status post; HeartbeatPayload / HeartbeatResponse
//	CertRotator  — mTLS renewal (see internal/transport for why it lives here)
//	LKGCapturer  — captures the last-known-good assignment set; BootLKG /
//	               LKGModule are its persisted shape
//
// Attach state itself is NOT owned by this package: it is mount.State,
// persisted at mount.StatePath (/persist/var/lib/powernode/state.json). Its
// LastAttachedManifestHashes map is what lets a restart skip re-pulling
// modules whose manifest has not changed. There is no ReconcilerState type
// and no /var/lib/powernode-agent/reconciler.json.
//
// Server-side counterparts:
//   - heartbeat:        extensions/system/server/app/controllers/api/v1/system/node_api/status_controller.rb
//   - module reconcile: ../node_api/modules_controller.rb
//   - runtime tasks:    ../node_api/runtime_controller.rb
package runtime
