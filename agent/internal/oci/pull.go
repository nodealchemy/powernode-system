// Package oci pulls module artifacts from a Powernode-controlled OCI
// registry (typically Gitea's container registry) using the `oras` CLI
// shelled out by the mount.Runner pattern. The agent only ever pulls
// (never pushes); module artifacts are produced by the M1 CI pipeline
// and ingested via the platform's webhook controller.
//
// Reference: Golden Eclipse plan M2.D.5; M1 supply chain.
package oci

import (
	"context"
	"errors"
	"fmt"
	"os"

	"github.com/powernode/platform/extensions/system/agent/internal/mount"
)

// Puller downloads OCI artifacts to a local cache.
type Puller struct {
	Runner mount.Runner
	Cache  string // root cache directory (typically /persist/cache/modules)
	// AuthCredentials is the per-instance oras login credential pair —
	// shape depends on the registry. Empty = anonymous (allowed for
	// public modules; production private registries require this).
	AuthUsername string
	AuthPassword string
}

// Pull fetches the module artifact at oci_ref into the cache directory.
// Returns the local path to the composefs metadata blob ("<digest>.cfs")
// and the path to the signature bundle (for cosign verification).
//
// Mirrors the M1 oras push: artifacts ship the composefs blob + cosign
// bundle + sbom + vex files, all addressable by digest.
func (p *Puller) Pull(ctx context.Context, ociRef, expectedDigest string) (cfsPath, bundlePath string, err error) {
	if ociRef == "" {
		return "", "", errors.New("Pull: empty oci_ref")
	}
	if p.Cache == "" {
		return "", "", errors.New("Pull: empty cache dir")
	}
	if err := os.MkdirAll(p.Cache, 0o755); err != nil {
		return "", "", fmt.Errorf("mkdir cache: %w", err)
	}

	args := []string{"pull", "--output", p.Cache, ociRef}
	if p.AuthUsername != "" {
		args = append([]string{"pull", "-u", p.AuthUsername, "-p", p.AuthPassword,
			"--output", p.Cache, ociRef}, args[len(args):]...)
	}
	if err := p.Runner.Run(ctx, "oras", args...); err != nil {
		return "", "", fmt.Errorf("oras pull %s: %w", ociRef, err)
	}

	// Per-arch artifact layout the M1 workflow produces:
	//   <cache>/module.cfs              — composefs blob
	//   <cache>/module.cosign-bundle    — cosign signature bundle
	//   <cache>/sbom.cdx.json           — SBOM (informational)
	//   <cache>/vex.json                — vulnerability statement
	cfsPath = p.Cache + "/module.cfs"
	bundlePath = p.Cache + "/module.cosign-bundle"
	if _, err := os.Stat(cfsPath); err != nil {
		return "", "", fmt.Errorf("expected %s after oras pull: %w", cfsPath, err)
	}
	return cfsPath, bundlePath, nil
}
