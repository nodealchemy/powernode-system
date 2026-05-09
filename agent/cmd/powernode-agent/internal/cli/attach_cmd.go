package cli

import (
	"context"
	"errors"
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
		return errResult("attach", ExitMountFailed, "attach", err),
			Errorf(ExitMountFailed, "attach", "%w", err)
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
