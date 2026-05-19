// Package systemd is the agent's thin layer over the systemd D-Bus +
// systemctl interface. Other packages (lifecycle, storage, dockerd,
// k3sd) drive unit files through this layer rather than shelling out
// to systemctl directly, so the call shape is consistent + testable.
//
// # Scope
//
// Owns:
//   - .service unit materialization (Write, Validate)
//   - daemon-reload coordination (batch reloads across many writes)
//   - enable / disable / start / stop / restart unit operations
//   - active-state + sub-state queries (is-active, is-enabled)
//
// Does NOT own:
//   - the contents of the unit files (callers compose those)
//   - .mount or .timer units beyond the same write-then-reload shape
//     (drivers in internal/storage compose .mount units and call into
//     this package to enable them)
//
// # Why a separate package
//
// Multiple callers need the same call shape (systemctl --no-pager show
// is a typical example of an under-specified flag set). Centralizing
// here means every caller gets the same error normalization +
// timeout behavior.
//
// # Reference
//
// Used by internal/lifecycle, internal/storage, internal/dockerd,
// internal/k3sd. Plan reference: P8.1 (systemd unit materialization).
package systemd
