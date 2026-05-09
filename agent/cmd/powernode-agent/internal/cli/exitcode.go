// Package cli holds CLI-only helpers: output formatting, exit-code
// constants, shared flag definitions, error types, and the cobra
// PreRunE builder. Lives at cmd/powernode-agent/internal/cli/ rather
// than internal/cli/ because these helpers are CLI-binary-specific
// (the long-running service doesn't need them).
package cli

// Exit codes follow a stable convention so operator scripts can
// branch on specific failure classes. Documented in the M2 plan and
// set via os.Exit by main() based on the error type.
const (
	ExitOK                = 0  // success
	ExitGeneric           = 1  // unspecified error (cobra default for RunE returns)
	ExitVerifyFailed      = 2  // cosign / fs-verity / checksum mismatch
	ExitMountFailed       = 3  // mount/filesystem operation failure
	ExitInitFailed        = 4  // systemd / init action failure
	ExitPlatformUnreached = 5  // platform unreachable / network failure
	ExitRefused           = 6  // refused operation (e.g., reboot_required without --force)
	ExitRefusedDestructive = 7 // refused destructive op (e.g., volume-setup on non-empty disk)
	ExitPartialSuccess    = 8  // some succeeded, some failed
	// 64+ reserved for command-specific (e.g., puppet --detailed-exitcodes 4→9, 6→10)
	ExitPuppetFailures = 9
	ExitPuppetMixed    = 10
)
