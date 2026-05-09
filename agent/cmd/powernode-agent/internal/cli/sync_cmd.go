package cli

import (
	"context"
	"fmt"

	"github.com/nodealchemy/powernode-system/agent/internal/runtime"
)

// SyncOptions drives `powernode-agent sync` — verbose plan-vs-execute
// reconcile + authorized_keys refresh. Operator-facing alias of
// update plus a few extra side-effects the long-loop service runs
// on its heartbeat tick.
type SyncOptions struct {
	PlatformURL string
	PKIDir      string
	DryRun      bool
	JSON        bool
}

// RunSync runs the operator-friendly equivalent of one heartbeat tick:
//  1. Module reconcile (same as `update`)
//  2. Authorized SSH keys refresh from /node_api/config/authorized_keys
//
// SDWAN/Docker/K3s reconcilers are NOT invoked from `sync` — those
// have their own per-tick state machines that are sensitive to being
// run out-of-band. Operators who need to force a docker/sdwan
// reconcile should restart the agent service.
func RunSync(ctx context.Context, opts SyncOptions) (Result, error) {
	cctx, err := BuildContext(opts.PlatformURL, opts.PKIDir)
	if err != nil {
		return errResult("sync", ExitPlatformUnreached, "build_context", err),
			Errorf(ExitPlatformUnreached, "sync", "%w", err)
	}

	r, err := BuildReconciler(cctx, opts.DryRun)
	if err != nil {
		return errResult("sync", ExitGeneric, "build_reconciler", err),
			Errorf(ExitGeneric, "sync", "%w", err)
	}

	stages := map[string]string{}

	if err := r.RunOnce(ctx); err != nil {
		stages["module_reconcile"] = "error: " + err.Error()
	} else {
		stages["module_reconcile"] = "ok"
	}

	if err := runtime.FetchAuthorizedKeys(ctx, runtime.AuthorizedKeysOptions{
		Client: cctx.Transport,
		OnWarn: func(stage string, err error) {
			stages["authorized_keys_warn:"+stage] = err.Error()
		},
	}); err != nil {
		stages["authorized_keys"] = "error: " + err.Error()
	} else {
		stages["authorized_keys"] = "ok"
	}

	failed := 0
	for k, v := range stages {
		_ = k
		if len(v) >= 5 && v[:5] == "error" {
			failed++
		}
	}

	res := Result{
		Command: "sync",
		Status:  "ok",
		Details: map[string]any{
			"dry_run": opts.DryRun,
			"stages":  stages,
		},
	}
	if failed > 0 {
		res.Status = "partial"
		res.ExitCode = ExitPartialSuccess
		res.Error = fmt.Sprintf("%d/%d stages failed", failed, len(stages))
		return res, Errorf(ExitPartialSuccess, "sync", "%d/%d stages failed", failed, len(stages))
	}
	return res, nil
}
