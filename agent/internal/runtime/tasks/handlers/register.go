package handlers

import "github.com/nodealchemy/powernode-system/agent/internal/runtime/tasks"

// RegisterDefaults wires the standard set of TaskHandlers the agent
// supports in Phase 1. Volume / network / backup / module-build
// handlers are deferred to Phase 2 — their command surface lives in
// dependent extension packages (volumes.go, network.go, etc.) that
// can land independently as the platform's task contract grows.
//
// Phase 1 coverage:
//   - lifecycle: start, stop, restart, reboot, terminate
//   - config: sync, sync_modules, apply_config (drives the reconciler)
//   - ssh: ssh_command, custom
//   - passthrough: provision, deprovision (platform-side concepts)
func RegisterDefaults(r *tasks.Registry, deps tasks.Dependencies) {
	RegisterLifecycle(r, deps)
	RegisterConfig(r, deps)
	RegisterSSH(r, deps)
	RegisterPassthrough(r, deps)
}
