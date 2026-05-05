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
//   1. POST /node_api/status with heartbeat (uptime, version, last result)
//   2. POST /node_api/modules → reconcile assignments → mount/composefs.Apply
//   3. dockerd.Manager.Tick (if docker-engine module assigned)
//   4. k3sd.Manager.Tick (if k3s-server / k3s-agent module assigned)
//   5. sdwan.Manager.Tick — apply wg + nft + FRR config from platform
//   6. transport.Mtls.RotateIfNearExpiry — auto-renews cert at 30 days
//   7. Sleep until next interval
//
// # Key types
//
//   Config            — { PlatformURL, AgentVersion, HeartbeatInterval, PKIDir, ... }
//   Service           — orchestrates the tick loop; lifecycle: New → Run(ctx) → Cancel
//   ReconcilerState   — persisted between restarts at /var/lib/powernode-agent/reconciler.json
//
// Reconciler state cache (per recent commit cff010a) survives across agent
// restarts — avoids re-doing module pulls on quick service restart.
//
// Server-side counterparts:
//   - heartbeat:        extensions/system/server/app/controllers/api/v1/system/node_api/status_controller.rb
//   - module reconcile: ../node_api/modules_controller.rb
//   - runtime tasks:    ../node_api/runtime_controller.rb
package runtime
