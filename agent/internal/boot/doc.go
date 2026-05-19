// Package boot implements the agent's first-boot orchestration — the work
// that runs from initramfs init-bottom before the real rootfs is pivoted
// in via switch_root.
//
// # Compose pattern
//
// This package owns no primitives of its own; it composes identity
// discovery + enrollment + mount orchestration into a single Boot(ctx)
// flow. The primitives all have their own tests and live in their own
// packages:
//
//   - internal/identity — discover who-am-I (cloud / libvirt / cmdline)
//   - internal/enroll   — CSR → mTLS cert exchange
//   - internal/mount    — composefs + overlayfs assembly
//   - internal/transport — HTTP client used by enroll
//
// # Switch-root injection
//
// SwitchRootFn is the function the orchestrator calls to pivot into the
// assembled rootfs. Defined as a function-typed field on the Orchestrator
// so tests can inject a stub — `systemctl switch-root` in production
// replaces the running process and never returns.
//
// # Reference
//
// Phase 3 of the agent stub implementation plan. See boot.go for the
// concrete Orchestrator + Boot(ctx) entry point.
package boot
