package cli

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/verify"
)

// VerifyOptions drives `powernode-agent verify`. Local-only — operates
// on a path the operator passes in, with the cosign bundle either
// supplied via flag or auto-discovered as <module>.cosign-bundle next
// to the artifact.
//
// Trust anchor, one of:
//   - KeyPaths / KeyDir — static-key verification against the platform's
//     module-signing PUBLIC keys. THIS is the platform's signing shape.
//     Constructed through verify.NewModuleVerifier (enforcing, SiteCLI),
//     the same constructor the runtime's mount sites resolve through, so a
//     green verdict here is exactly what an enforcing node would accept.
//   - IdentityRegexp + IssuerRegexp — keyless Fulcio pins, for artifacts
//     signed on a genuinely Fulcio-trusted CI. No platform pipeline
//     produces these today.
type VerifyOptions struct {
	ModulePath     string
	BundlePath     string
	Digest         string
	KeyPaths       []string
	KeyDir         string // every *.pub in this dir is trusted (the runtime's platform-key cache shape)
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

	keys := append([]string(nil), opts.KeyPaths...)
	if opts.KeyDir != "" {
		dirKeys, err := pubKeysIn(opts.KeyDir)
		if err != nil {
			return errResult("verify", ExitGeneric, "key_dir", err), Errorf(ExitGeneric, "verify", "%v", err)
		}
		keys = append(keys, dirKeys...)
	}
	var (
		cosignVer verify.Verifier
		trust     string
	)
	if len(keys) > 0 {
		// Same constructor as the runtime's mount sites; enforcing so a
		// failure is a failure, not an audit report.
		v, err := verify.NewModuleVerifier(verify.ModuleSigningConfig{Mode: verify.ModeAll, KeyPaths: keys}, verify.SiteCLI, opts.Runner, nil)
		if err != nil {
			return errResult("verify", ExitGeneric, "trust_anchor", err), Errorf(ExitGeneric, "verify", "%v", err)
		}
		cosignVer, trust = v, "static-key"
	} else {
		cosignVer = &verify.CosignVerifier{
			Runner:         opts.Runner,
			IdentityRegexp: opts.IdentityRegexp,
			IssuerRegexp:   opts.IssuerRegexp,
		}
		trust = "keyless"
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
		"trust":          trust,
		"trusted_keys":   len(keys),
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

// pubKeysIn lists every *.pub in dir, sorted — the runtime caches the
// platform's trusted keys under /persist/var/lib/powernode/module-signing/
// platform-keys/ in exactly this shape.
func pubKeysIn(dir string) ([]string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("--key-dir %s: %w", dir, err)
	}
	var keys []string
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".pub") {
			keys = append(keys, filepath.Join(dir, e.Name()))
		}
	}
	if len(keys) == 0 {
		return nil, fmt.Errorf("--key-dir %s: no *.pub files", dir)
	}
	return keys, nil
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
