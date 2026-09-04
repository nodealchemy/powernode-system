package cli

import (
	"errors"
	"fmt"
	"os"

	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/oci"
	"github.com/nodealchemy/powernode-system/agent/internal/runtime"
	"github.com/nodealchemy/powernode-system/agent/internal/verify"
)

// BuildReconciler constructs a runtime.Reconciler wired to the
// command's mTLS context. Used by the `update`, `sync`, `attach`,
// `detach` CLI commands. The reconciler shares the same primitives
// as the long-loop service reconciler (oci.Puller, manifest cache,
// mount.Runner, verify.Verifier) so behavior stays consistent.
//
// The module-signature Verifier is resolved from the operator's persisted
// policy (runtime.LoadModuleSigningConfig: conf file + env) for the CLI site
// — verify.AlwaysOK by DEFAULT, a static-key CosignVerifier against the
// platform's trusted keys under the runtime/all modes, its audit wrapper
// under audit. Same resolver, same verifier as the service loop.
func BuildReconciler(cctx *Context, dryRun bool) (*runtime.Reconciler, error) {
	if cctx == nil || cctx.Transport == nil {
		return nil, errors.New("BuildReconciler: nil context")
	}
	signing, err := runtime.LoadModuleSigningConfig(nil, "")
	if err != nil {
		return nil, fmt.Errorf("module signing: %w", err)
	}
	moduleVerifier, err := runtime.ResolveModuleVerifier(signing, verify.SiteCLI, cctx.Transport, mount.ExecRunner{}, "", func(stage string, err error) {
		fmt.Fprintf(os.Stderr, "[powernode-agent %s] %v\n", stage, err)
	})
	if err != nil {
		return nil, fmt.Errorf("module signing: %w", err)
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
		},
		Verifier:    moduleVerifier,
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
