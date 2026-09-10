// Package dockerd reconciles managed Docker daemon state on a NodeInstance.
//
// Ships the Phase 1 container runtime path: when a NodeInstance has the
// docker-engine module assigned, this package installs docker-ce, generates
// an Ed25519 server keypair, posts a CSR to the platform's runtime/handshake
// endpoint, writes /etc/docker/daemon.json with TLS + a /128 listen address,
// and starts dockerd via systemd.
//
// # State machine
//
//	┌──────────────┐
//	│   detected   │  module assignment seen on reconcile tick
//	└──────┬───────┘
//	       │ install docker-ce
//	       ▼
//	┌──────────────┐
//	│  installing  │
//	└──────┬───────┘
//	       │ generate keypair, build CSR
//	       ▼
//	┌──────────────┐
//	│ wants_cert   │  POST /runtime/handshake (phase=wants_cert)
//	└──────┬───────┘
//	       │ platform signs CSR; returns cert + chain
//	       ▼
//	┌──────────────┐
//	│  applying    │  write daemon.json + restart docker.service
//	└──────┬───────┘
//	       │ verify daemon listens; query /info
//	       ▼
//	┌──────────────┐
//	│    ready     │  POST /runtime/handshake (phase=ready)
//	└──────────────┘
//
// # Key types
//
//	Manager        — orchestrates the state machine via Tick
//	DaemonApplier  — the side-effect seam (install + daemon.json + systemd)
//	ShellApplier   — production implementation; apt + systemctl shellouts
//	Client         — typed client for the handshake endpoint; the wire types
//	                 are HandshakeRequest, ReadyAck, StoppedAck and
//	                 HandshakeError, with Phase naming the phase constant
//	DaemonConfig   — the daemon.json the applier writes
//	DaemonPaths    — where on disk it writes; DefaultPaths in production
//	RuntimeEnsurer — optional isolation runtimes (KataRuntimeEnsurer,
//	                 GvisorRuntimeEnsurer, composed by CompositeRuntimeEnsurer)
//
// The install + config + systemd work is NOT in a separate package: applier.go
// and shell_applier.go are in this one, alongside the wire protocol.
//
// Slice 10 (config-variety daemon.json overrides) is applied here: child
// modules with higher effective_priority have their daemon.json contributions
// merged into the base config.
//
// # Handshake phases
//
// The protocol surface (POST /api/v1/system/node_api/runtime/handshake) is
// defined platform-side in runtime_controller.rb; this package is the typed Go
// client for it.
//
//	wants_cert: agent generates an Ed25519 keypair, builds a CSR with
//	            CN = "docker-daemon-<node_instance_id>", POSTs the CSR.
//	            Platform returns the CA-signed leaf cert + CA chain.
//	            Idempotent — repeated calls re-issue cleanly, so cert
//	            rotation rides the same code path.
//
//	ready:      agent reports dockerd is up, with observed version. Platform
//	            flips the managed Devops::DockerHost row from `pending` to
//	            `connected`. Sent once per dockerd start.
//
//	stopped:    agent reports dockerd is no longer listening (clean shutdown,
//	            module unassignment). Platform flips the host to
//	            `disconnected`. Sent best-effort during teardown.
//
// Server-side counterpart: extensions/system/server/app/services/system/
// docker_daemon_provisioner_service.rb handles platform-side bookkeeping.
package dockerd
