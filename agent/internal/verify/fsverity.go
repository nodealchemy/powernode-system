package verify

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// DigestVerifier is the fs-verity arm of the module-mount gate
// (ReconcilerConfig.Fsverity): nil skips it, FsVerifier enforces, and
// AuditDigestVerifier measures. Sites obtain it from NewModuleFsverity.
type DigestVerifier interface {
	VerifyDigest(ctx context.Context, path, expected string) error
}

// AuditDigestVerifier runs Inner and reports — but never returns — its
// failures. It is the fs-verity counterpart of AuditVerifier.
type AuditDigestVerifier struct {
	Inner  DigestVerifier
	Report func(stage string, err error)
}

// VerifyDigest always returns nil; a failure from Inner is passed to Report
// under the stage "verify:module_fsverity_audit" with the blob path.
func (a AuditDigestVerifier) VerifyDigest(ctx context.Context, path, expected string) error {
	if a.Inner == nil {
		return nil
	}
	if err := a.Inner.VerifyDigest(ctx, path, expected); err != nil && a.Report != nil {
		a.Report("verify:module_fsverity_audit", fmt.Errorf("would refuse %s: %w", path, err))
	}
	return nil
}

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
		// Fail closed. A check with nothing to compare against is a silent
		// bypass; name the cause, which is on the publish side.
		return errors.New("no fsverity_root_hash published for this artifact; nothing to verify the blob against")
	}
	if err := v.Enable(ctx, path); err != nil {
		// Don't fail on already-enabled or on a filesystem without verity
		// support — the userspace digest below still catches tampering.
		// mount.ExecRunner embeds the CLI's output, and fsverity-utils prints
		// strerror text ("Operation not supported", "File exists"), not the
		// errno names, so match both. Surface only unexpected errors.
		if !enableErrTolerable(err.Error()) {
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

// enableErrTolerable reports whether an `fsverity enable` failure means
// "already enabled" or "not supported on this filesystem", in either the
// errno-name or the strerror form.
func enableErrTolerable(msg string) bool {
	for _, s := range []string{"EOPNOTSUPP", "Operation not supported", "EEXIST", "File exists", "already enabled"} {
		if strings.Contains(msg, s) {
			return true
		}
	}
	return false
}
