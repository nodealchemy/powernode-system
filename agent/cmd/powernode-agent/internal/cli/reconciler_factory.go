package cli

import (
	"errors"
	"fmt"

	"github.com/powernode/platform/extensions/system/agent/internal/manifest"
	"github.com/powernode/platform/extensions/system/agent/internal/mount"
	"github.com/powernode/platform/extensions/system/agent/internal/oci"
	"github.com/powernode/platform/extensions/system/agent/internal/runtime"
	"github.com/powernode/platform/extensions/system/agent/internal/verify"
)

// BuildReconciler constructs a runtime.Reconciler wired to the
// command's mTLS context. Used by the `update`, `sync`, `attach`,
// `detach` CLI commands. The reconciler shares the same primitives
// as the long-loop service reconciler (oci.Puller, manifest cache,
// mount.Runner, verify.Verifier) so behavior stays consistent.
//
// Phase 2 default Verifier is verify.AlwaysOK to match the service-
// loop default. Operators running production attach/update flows
// should pass a real CosignVerifier via the FactoryConfig override
// once the M1 publish pipeline ships pinned signatures.
func BuildReconciler(cctx *Context, dryRun bool) (*runtime.Reconciler, error) {
	if cctx == nil || cctx.Transport == nil {
		return nil, errors.New("BuildReconciler: nil context")
	}
	cfg := runtime.FactoryConfig{
		ModulesClient:  cctx.Transport,
		ManifestClient: cctx.Transport,
		ManifestRoot:   manifest.DefaultRoot,
		Puller: &oci.Puller{
			Transport:   cctx.Transport,
			HTTPClient:  cctx.Transport.Client,
			PlatformURL: cctx.Transport.PlatformURL,
			Cache:       "/persist/cache/modules",
			AuthHeader:  bearerHeaderFromContext(cctx),
		},
		Verifier:    verify.AlwaysOK{},
		MountRunner: mount.ExecRunner{},
		Layout:      mount.DefaultLayout(),
		StatePath:   mount.StatePath,
		DryRun:      dryRun,
	}
	r, err := runtime.NewReconcilerForCLI(cfg)
	if err != nil {
		return nil, fmt.Errorf("build reconciler: %w", err)
	}
	return r, nil
}

func bearerHeaderFromContext(c *Context) string {
	if c == nil || c.Transport == nil || c.Transport.InstanceToken == "" {
		return ""
	}
	return "Bearer " + c.Transport.InstanceToken
}
