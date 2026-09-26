package cli

import (
	"context"
	"errors"
	"strings"

	"github.com/nodealchemy/powernode-system/agent/internal/runtime"
)

// AttachOptions drives `powernode-agent attach <module-id>`. Single-
// module hot-add: pull + verify + mount + start units, no full
// reconcile cycle. Useful for operator-driven attaching of a debug
// module without waiting for the next service tick.
type AttachOptions struct {
	ModuleID    string
	PlatformURL string
	PKIDir      string
	DryRun      bool
	JSON        bool
}

// RunAttach delegates to Reconciler.AttachOne. Idempotent: returns
// status=already_attached when state.json already shows the module
// at the same digest.
func RunAttach(ctx context.Context, opts AttachOptions) (Result, error) {
	if opts.ModuleID == "" {
		return errResult("attach", ExitGeneric, "missing_module_id", errors.New("module-id required")),
			Errorf(ExitGeneric, "attach", "module-id required")
	}
	cctx, err := BuildContext(opts.PlatformURL, opts.PKIDir)
	if err != nil {
		return errResult("attach", ExitPlatformUnreached, "build_context", err),
			Errorf(ExitPlatformUnreached, "attach", "%w", err)
	}
	r, err := BuildReconciler(cctx, opts.DryRun)
	if err != nil {
		return errResult("attach", ExitGeneric, "build_reconciler", err),
			Errorf(ExitGeneric, "attach", "%w", err)
	}
	status, err := r.AttachOne(ctx, opts.ModuleID)
	if err != nil {
		return attachErrorResult(opts.ModuleID, err)
	}
	return Result{
		Command: "attach",
		Status:  "ok",
		Details: map[string]any{
			"module_id":     opts.ModuleID,
			"attach_status": status,
		},
	}, nil
}

// attachErrorResult maps an AttachOne error to the CLI's Result/exit-code
// shape. Extracted from RunAttach so this mapping is testable without
// BuildReconciler's real platform context (J2, review round 5).
//
// J2: AttachOne runs in THIS process, which exits right after RunAttach
// returns — there is no daemon-side SecurityFailClosedUnits()/heartbeat/
// sensor reader to fall back on for this refusal (H1's attempt to publish it
// there was reverted as dead code once that was established). This CLI's own
// exit code and printed unit list are the only durable signal it gets, so a
// security-policy refusal (*runtime.SecurityFailClosedError) is
// distinguished from an ordinary mount/pull failure (ExitMountFailed) rather
// than folded into it.
func attachErrorResult(moduleID string, err error) (Result, error) {
	var secErr *runtime.SecurityFailClosedError
	if errors.As(err, &secErr) {
		res := errResult("attach", ExitSecurityFailClosed, "security_fail_closed", err)
		res.Details = map[string]any{
			"module_id":     moduleID,
			"refused_units": secErr.Units,
		}
		return res, Errorf(ExitSecurityFailClosed, "attach",
			"module %s: refusing to (re)attach/start — security drop-in write failed and was not exempt for unit(s) %s",
			moduleID, strings.Join(secErr.Units, ", "))
	}
	return errResult("attach", ExitMountFailed, "attach", err),
		Errorf(ExitMountFailed, "attach", "%w", err)
}
