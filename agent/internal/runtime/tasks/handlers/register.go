package handlers

import "github.com/nodealchemy/powernode-system/agent/internal/runtime/tasks"

// RegisterDefaults wires the standard set of TaskHandlers the agent
// supports. Volume / network / backup handlers are deferred to Phase 2 —
// their command surface lives in dependent extension packages (volumes.go,
// network.go, etc.) that can land independently as the platform's task
// contract grows.
//
// Coverage:
//   - lifecycle: start, stop, restart, reboot, terminate
//   - config: sync, sync_modules, apply_config (drives the reconciler)
//   - ssh: ssh_command, custom
//   - passthrough: provision, deprovision (platform-side concepts)
//   - a2a: a2a_call (execute a mission-delegated peer call over the A2A mesh)
//   - module_build: ci.module_build (native NodeModule build on a leased
//     module-forge builder — campaign 019f5885 inc7)
func RegisterDefaults(r *tasks.Registry, deps tasks.Dependencies) {
	RegisterLifecycle(r, deps)
	RegisterConfig(r, deps)
	RegisterSSH(r, deps)
	RegisterPassthrough(r, deps)
	RegisterStorage(r, deps)
	RegisterA2ADelegate(r, deps)
	RegisterUpgradeBootImage(r, deps)
	RegisterModuleBuild(r, deps)
}
