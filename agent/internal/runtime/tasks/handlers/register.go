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
//   - package_build: ci.package_build (native materialized-package build on
//     the SAME leased module-forge builder — campaign 019f6084 inc-D)
//   - probe_module_smoke: probe.module_smoke (structured post-compose health
//     checks — systemd unit active, health endpoint, ldd closure — the
//     agent side of System::ModuleSmokeProbe's dispatch/poll; campaign
//     019f6084 inc-E)
func RegisterDefaults(r *tasks.Registry, deps tasks.Dependencies) {
	RegisterLifecycle(r, deps)
	RegisterConfig(r, deps)
	RegisterSSH(r, deps)
	RegisterPassthrough(r, deps)
	RegisterStorage(r, deps)
	RegisterA2ADelegate(r, deps)
	RegisterUpgradeBootImage(r, deps)
	RegisterModuleBuild(r, deps)
	RegisterPackageBuild(r, deps)
	RegisterProbeModuleSmoke(r, deps)
}
