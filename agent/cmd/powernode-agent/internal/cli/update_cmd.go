package cli

import (
	"context"
	"errors"
)

// UpdateOptions drives `powernode-agent update`. One synchronous
// reconcile cycle: pull desired-state modules from platform, diff
// vs. on-disk state, attach/detach to converge.
type UpdateOptions struct {
	PlatformURL string
	PKIDir      string
	DryRun      bool
	JSON        bool
}

// RunUpdate runs one reconcile cycle and reports the outcome.
func RunUpdate(ctx context.Context, opts UpdateOptions) (Result, error) {
	cctx, err := BuildContext(opts.PlatformURL, opts.PKIDir)
	if err != nil {
		return errResult("update", ExitPlatformUnreached, "build_context", err),
			Errorf(ExitPlatformUnreached, "update", "%w", err)
	}

	r, err := BuildReconciler(cctx, opts.DryRun)
	if err != nil {
		return errResult("update", ExitGeneric, "build_reconciler", err),
			Errorf(ExitGeneric, "update", "%w", err)
	}

	if err := r.RunOnce(ctx); err != nil {
		return errResult("update", ExitGeneric, "reconcile", err),
			Errorf(ExitGeneric, "update:reconcile", "%w", err)
	}

	res := Result{
		Command: "update",
		Status:  "ok",
		Details: map[string]any{
			"dry_run":            opts.DryRun,
			"last_reconcile_at":  r.LastReconcileAt(),
		},
	}
	if r.LastError() != nil {
		res.Status = "partial"
		res.Error = r.LastError().Error()
	}
	_ = errors.Is // silence unused import in some build modes
	return res, nil
}
