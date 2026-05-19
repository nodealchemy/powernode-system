// Package lifecycle materializes systemd unit files from the platform's
// system_module_services rows (surfaced to the agent as manifest.Service
// entries) and wires them into module attach/detach.
//
// # Why systemd-native
//
// Each service inherits all of systemd's lifecycle guarantees:
//   - Restart= for restart_policy
//   - Environment= for env
//   - User= for user
//   - journalctl for stdout/stderr
//
// without the agent reimplementing a process supervisor.
//
// # Topological start order
//
// Outgoing dependencies on a service mean "start these first." The
// service materializer uses Kahn's algorithm to produce a deterministic
// start order, with a stable secondary key (name asc) so two independent
// services always land in the same order across reconcile passes.
//
// # Unit naming
//
//	powernode-<module-id>-<service-name>.service
//
// The per-module prefix scopes them so two modules can ship services with
// the same human name without colliding.
//
// # Reference
//
// Plan reference: P8.1 (ipn-agent init_start/init_stop per
// system_module_services rows).
package lifecycle
