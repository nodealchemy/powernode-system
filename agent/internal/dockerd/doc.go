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
//	             ┌──────────────┐
//	             │   detected   │  module assignment seen on reconcile tick
//	             └──────┬───────┘
//	                    │ install docker-ce
//	                    ▼
//	             ┌──────────────┐
//	             │  installing  │
//	             └──────┬───────┘
//	                    │ generate keypair, build CSR
//	                    ▼
//	             ┌──────────────┐
//	             │ wants_cert   │  POST /runtime/handshake (phase=wants_cert)
//	             └──────┬───────┘
//	                    │ platform signs CSR; returns cert + chain
//	                    ▼
//	             ┌──────────────┐
//	             │  applying    │  write daemon.json + restart docker.service
//	             └──────┬───────┘
//	                    │ verify daemon listens; query /info
//	                    ▼
//	             ┌──────────────┐
//	             │    ready     │  POST /runtime/handshake (phase=ready)
//	             └──────────────┘
//
// # Key types
//
//   Manager       — orchestrates the state machine via Tick
//   Applier       — interface for the side-effect path (install + config + systemd)
//   ShellApplier  — production implementation; uses apt + systemctl shellouts
//   Handshake     — client for /api/v1/system/node_api/runtime/handshake
//
// Slice 10 (config-variety daemon.json overrides) is applied here: child
// modules with higher effective_priority have their daemon.json contributions
// merged into the base config.
//
// Server-side counterpart: extensions/system/server/app/services/system/
// docker_daemon_provisioner_service.rb handles platform-side bookkeeping.
package dockerd
