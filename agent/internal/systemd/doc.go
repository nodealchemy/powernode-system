// Package systemd is the agent's thin wrapper over systemctl. Every call goes
// through a mount.Runner, so production shells out while tests use
// mount.RecorderRunner to assert the exact command sequence. There is no
// D-Bus client.
//
// # API
//
//	Action       — systemctl <verb> <unit>, for an allow-listed ActionVerb
//	ActionVerb   — Start, Stop, Restart, Reload, Status
//	IsActive     — true iff `systemctl is-active <unit>` prints "active"
//	DaemonReload — systemctl daemon-reload, after dropping in unit files
//
// A unit name is validated before it reaches the command line, so a crafted
// name cannot smuggle in extra flags or commands. enable and disable are not
// in the allow-list.
//
// # Scope
//
// Owns the call shape: argument validation and error wrapping. Does NOT own
// the contents of unit files; callers render and write those.
//
// # Callers
//
// internal/lifecycle, internal/migration, the runtime lifecycle task handler
// and the CLI's init command. internal/storage writes and drives its own
// .mount units through a mount.Runner directly, not through this package.
package systemd
