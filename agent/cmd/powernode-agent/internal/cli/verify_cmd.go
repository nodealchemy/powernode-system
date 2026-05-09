package cli

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/powernode/platform/extensions/system/agent/internal/mount"
	"github.com/powernode/platform/extensions/system/agent/internal/verify"
)

// VerifyOptions drives `powernode-agent verify`. Local-only — operates
// on a path the operator passes in, with the cosign bundle either
// supplied via flag or auto-discovered as <module>.cosign-bundle next
// to the artifact.
type VerifyOptions struct {
	ModulePath     string
	BundlePath     string
	Digest         string
	IdentityRegexp string
	IssuerRegexp   string
	JSON           bool
	Runner         mount.Runner
	Out            io.Writer
}

// RunVerify exercises both cosign blob signature verification and
// fs-verity Merkle-root verification against the supplied path.
//
// Output (human mode):
//
//	module:    /persist/cache/modules/<digest>.cfs
//	cosign:    OK (issuer=...)
//	fsverity:  OK (digest=abc123…)
//	verdict:   verified
//
// Exit codes:
//
//	0 verified
//	2 unverified (cosign or fs-verity rejection)
//	1 operational error (file missing, bundle unreadable)
func RunVerify(ctx context.Context, opts VerifyOptions) (Result, error) {
	if opts.ModulePath == "" {
		return errResult("verify", ExitGeneric, "missing_module", errors.New("module path required")),
			Errorf(ExitGeneric, "verify", "module path required")
	}
	if opts.Runner == nil {
		opts.Runner = mount.ExecRunner{}
	}
	if opts.BundlePath == "" {
		opts.BundlePath = opts.ModulePath + ".cosign-bundle"
		if !fileExists(opts.BundlePath) {
			// Also try replacing .cfs with .cosign-bundle (canonical layout).
			alt := strings.TrimSuffix(opts.ModulePath, ".cfs") + ".cosign-bundle"
			if fileExists(alt) {
				opts.BundlePath = alt
			}
		}
	}

	if !fileExists(opts.ModulePath) {
		return errResult("verify", ExitGeneric, "module_missing", fmt.Errorf("%s not found", opts.ModulePath)),
			Errorf(ExitGeneric, "verify", "module %s not found", opts.ModulePath)
	}

	cosignVer := &verify.CosignVerifier{
		Runner:         opts.Runner,
		IdentityRegexp: opts.IdentityRegexp,
		IssuerRegexp:   opts.IssuerRegexp,
	}
	cosignErr := cosignVer.VerifyBlob(ctx, opts.ModulePath, opts.BundlePath)

	fsVer := &verify.FsVerifier{Runner: opts.Runner}
	var fsErr error
	var fsDigest string
	if opts.Digest != "" {
		fsErr = fsVer.VerifyDigest(ctx, opts.ModulePath, opts.Digest)
		fsDigest = strings.TrimPrefix(opts.Digest, "sha256:")
	} else {
		fsDigest, fsErr = fsVer.Digest(ctx, opts.ModulePath)
	}

	verdict := "verified"
	exitCode := ExitOK
	stage := ""
	switch {
	case cosignErr != nil:
		verdict = "cosign_unverified"
		exitCode = ExitVerifyFailed
		stage = "cosign"
	case opts.Digest != "" && fsErr != nil:
		verdict = "fsverity_mismatch"
		exitCode = ExitVerifyFailed
		stage = "fsverity"
	}

	details := map[string]any{
		"module":         opts.ModulePath,
		"bundle":         opts.BundlePath,
		"cosign_status":  describeError(cosignErr),
		"fsverity":       fsDigest,
		"fsverity_check": describeError(fsErr),
		"verdict":        verdict,
	}
	r := Result{
		Command:  "verify",
		Status:   conditional(exitCode == ExitOK, "ok", "error"),
		ExitCode: exitCode,
		Stage:    stage,
		Details:  details,
	}
	if exitCode != ExitOK {
		var combinedErr error
		switch {
		case cosignErr != nil:
			combinedErr = fmt.Errorf("cosign: %w", cosignErr)
		case fsErr != nil:
			combinedErr = fmt.Errorf("fs-verity: %w", fsErr)
		default:
			combinedErr = errors.New("unknown verify failure")
		}
		r.Error = combinedErr.Error()
		return r, Errorf(exitCode, "verify:"+stage, "%s", combinedErr)
	}
	return r, nil
}

func fileExists(p string) bool {
	st, err := os.Stat(p)
	return err == nil && !st.IsDir()
}

func describeError(err error) string {
	if err == nil {
		return "OK"
	}
	return err.Error()
}

func conditional(cond bool, t, f string) string {
	if cond {
		return t
	}
	return f
}
