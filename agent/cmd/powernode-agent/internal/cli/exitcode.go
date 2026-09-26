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
	ExitOK                 = 0 // success
	ExitGeneric            = 1 // unspecified error (cobra default for RunE returns)
	ExitVerifyFailed       = 2 // cosign / fs-verity / checksum mismatch
	ExitMountFailed        = 3 // mount/filesystem operation failure
	ExitInitFailed         = 4 // systemd / init action failure
	ExitPlatformUnreached  = 5 // platform unreachable / network failure
	ExitRefused            = 6 // refused operation (e.g., reboot_required without --force)
	ExitRefusedDestructive = 7 // refused destructive op (e.g., volume-setup on non-empty disk)
	ExitPartialSuccess     = 8 // some succeeded, some failed
	// 64+ reserved for command-specific (e.g., puppet --detailed-exitcodes 4→9, 6→10)
	ExitPuppetFailures = 9
	ExitPuppetMixed    = 10
	// ExitDryRunWouldRefuse is returned by a prepare/dry-run mode (no
	// --execute) when the same operation WOULD be refused under --execute.
	// Distinct from ExitOK (would succeed) and ExitGeneric (the command
	// itself errored) so a CI wrapper can gate on "the dry run says the real
	// run would be blocked" without conflating it with success or a crash.
	// Used by `soft-recompose` (no --execute) when NextrootSurvivalGate would
	// refuse the soft-reboot.
	ExitDryRunWouldRefuse = 11
	// ExitDryRunGateUnavailable is returned by a prepare/dry-run mode when the
	// gate could not reach a verdict at all — as distinct from reaching one and
	// refusing (IMP-de738c292bf9). A failed `systemctl daemon-reload` (EPERM for
	// a non-root caller) or an unreadable mount table means nothing is known
	// about survival either way. Conflating it with ExitDryRunWouldRefuse told a
	// CI wrapper "this node needs mount drop-ins" while the real problem — the
	// gate never ran — was never surfaced, sending the operator after the wrong
	// fix. Still non-zero: no caller may soft-reboot on an unknown verdict.
	ExitDryRunGateUnavailable = 12
	// ExitSecurityFailClosed is returned by `attach` when the module's
	// security policy refused to (re)attach it — a non-exempt drop-in write
	// failure, an unapproved privileged request, or an invalid policy block
	// (runtime.SecurityFailClosedError specifically; the other two share
	// this code too since they are the SAME refusal family attachModule
	// returns from, just without a typed error naming units). Distinct from
	// ExitMountFailed (a pull/verify/mount problem — the module's own
	// content) and from ExitRefused (an operator-facing "did you mean it"
	// refusal like reboot_required): this is neither — it is the agent's
	// OWN confinement policy declining to run the module unconfined (J2,
	// review round 5). AttachOne runs inside this CLI's own process and has
	// no daemon-side SecurityFailClosedUnits() reader to fall back on, so
	// this exit code plus RunAttach's printed unit list is the only durable
	// signal an operator or wrapper script gets for this specific refusal.
	ExitSecurityFailClosed = 13
)
