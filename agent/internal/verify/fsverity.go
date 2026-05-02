package verify

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/powernode/platform/extensions/system/agent/internal/mount"
)

// FsVerifier wraps the `fsverity` CLI for enabling fs-verity on a freshly
// pulled blob and verifying the on-disk root hash matches the platform's
// recorded value.
type FsVerifier struct {
	Runner mount.Runner
}

// Enable turns on fs-verity for the given file. Once enabled, the file
// becomes read-only and any I/O against it triggers Merkle-tree-backed
// integrity checks at file-open time.
func (v *FsVerifier) Enable(ctx context.Context, path string) error {
	if path == "" {
		return errors.New("Enable: path required")
	}
	return v.Runner.Run(ctx, "fsverity", "enable", path)
}

// Digest returns the SHA-256 fs-verity root hash of the file as a hex
// string (without prefix). Compared with platform's
// ModuleArtifact.fsverity_root_hash to detect tampering between build
// and mount.
func (v *FsVerifier) Digest(ctx context.Context, path string) (string, error) {
	if path == "" {
		return "", errors.New("Digest: path required")
	}
	out, err := v.Runner.Output(ctx, "fsverity", "digest", "--hash-alg", "sha256", path)
	if err != nil {
		return "", fmt.Errorf("fsverity digest: %w", err)
	}
	// fsverity prints "<hash> <path>"; we want just the hash
	first := bytes.SplitN(out, []byte{' '}, 2)
	if len(first) == 0 {
		return "", errors.New("fsverity digest produced no output")
	}
	return strings.TrimSpace(string(first[0])), nil
}

// VerifyDigest enables fs-verity (idempotent — re-enable is harmless on
// already-verified files in modern kernels) and asserts the resulting
// digest matches `expected`. Combined Enable+Digest is the canonical
// pre-mount check.
func (v *FsVerifier) VerifyDigest(ctx context.Context, path, expected string) error {
	if expected == "" {
		return errors.New("VerifyDigest: expected hash required (no-op pre-checks are a footgun)")
	}
	if err := v.Enable(ctx, path); err != nil {
		// Don't fail on already-enabled — the digest check below will
		// catch any tampering anyway. Surface only unexpected errors.
		if !strings.Contains(err.Error(), "EOPNOTSUPP") &&
			!strings.Contains(err.Error(), "EEXIST") &&
			!strings.Contains(err.Error(), "already enabled") {
			return err
		}
	}
	got, err := v.Digest(ctx, path)
	if err != nil {
		return err
	}
	got = strings.TrimPrefix(got, "sha256:")
	expected = strings.TrimPrefix(expected, "sha256:")
	if !strings.EqualFold(got, expected) {
		return fmt.Errorf("fs-verity digest mismatch: got %s, expected %s", got, expected)
	}
	return nil
}
