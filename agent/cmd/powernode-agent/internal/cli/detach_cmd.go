package cli

import (
	"context"
	"errors"
)

// DetachOptions drives `powernode-agent detach <module-id>`. Single-
// module reverse of attach: stop units + unmount + remove from stack.
// Cached blob is preserved by default (saves bandwidth on re-attach);
// future --purge-cache flag will remove it.
type DetachOptions struct {
	ModuleID    string
	PlatformURL string
	PKIDir      string
	DryRun      bool
	JSON        bool
}

// RunDetach delegates to Reconciler.DetachOne. Idempotent: returns
// status=already_detached when state.json doesn't show the module.
func RunDetach(ctx context.Context, opts DetachOptions) (Result, error) {
	if opts.ModuleID == "" {
		return errResult("detach", ExitGeneric, "missing_module_id", errors.New("module-id required")),
			Errorf(ExitGeneric, "detach", "module-id required")
	}
	cctx, err := BuildContext(opts.PlatformURL, opts.PKIDir)
	if err != nil {
		return errResult("detach", ExitPlatformUnreached, "build_context", err),
			Errorf(ExitPlatformUnreached, "detach", "%w", err)
	}
	r, err := BuildReconciler(cctx, opts.DryRun)
	if err != nil {
		return errResult("detach", ExitGeneric, "build_reconciler", err),
			Errorf(ExitGeneric, "detach", "%w", err)
	}
	status, err := r.DetachOne(ctx, opts.ModuleID)
	if err != nil {
		return errResult("detach", ExitMountFailed, "detach", err),
			Errorf(ExitMountFailed, "detach", "%w", err)
	}
	return Result{
		Command: "detach",
		Status:  "ok",
		Details: map[string]any{
			"module_id":     opts.ModuleID,
			"detach_status": status,
		},
	}, nil
}
