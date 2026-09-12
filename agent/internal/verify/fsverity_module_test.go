package verify

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// IMP-4eabe61c3d90 — the fs-verity arm of the module-mount gate, resolved from
// the same module-signing policy as the signature arm.

// DEFAULT OFF: the zero policy and every explicit off wire no fs-verity check
// at any site, exactly as before this arm was resolvable.
func TestNewModuleFsverityDefaultsToNoCheckAtEverySite(t *testing.T) {
	for _, cfg := range []ModuleSigningConfig{{}, {Mode: ModeOff}} {
		for _, site := range []Site{SiteService, SiteCLI, SiteBoot} {
			v, err := NewModuleFsverity(cfg, site, &mount.RecorderRunner{}, nil)
			if err != nil {
				t.Fatalf("mode %q at %s: %v", cfg.Mode, site, err)
			}
			if v != nil {
				t.Fatalf("mode %q at %s: want no fs-verity check (nil), got %T", cfg.Mode, site, v)
			}
		}
	}
}

// MEASURE-ONLY in every active mode at every site, enforcing modes included.
// No node image ships the fsverity binary, so an enforcing check would refuse
// every mount on every opted-in node; the arm reports until that ships.
func TestNewModuleFsverityMeasuresButNeverRefusesInEveryActiveMode(t *testing.T) {
	for _, mode := range []string{ModeAudit, ModeRuntime, ModeAll} {
		for _, site := range []Site{SiteService, SiteCLI, SiteBoot} {
			var reported []string
			// No keys: the fs-verity arm needs no trust anchor, unlike cosign.
			cfg := ModuleSigningConfig{Mode: mode}
			runner := &mount.RecorderRunner{StubErr: map[string]error{
				"fsverity enable /cache/m.erofs": errors.New(`exec: "fsverity": executable file not found in $PATH`),
			}}
			v, err := NewModuleFsverity(cfg, site, runner, func(stage string, err error) {
				reported = append(reported, stage+": "+err.Error())
			})
			if err != nil {
				t.Fatalf("mode %s at %s: %v", mode, site, err)
			}
			if v == nil {
				t.Fatalf("mode %s at %s: an active mode must wire the fs-verity check", mode, site)
			}
			if _, ok := v.(AuditDigestVerifier); !ok {
				t.Fatalf("mode %s at %s: want the measure-only AuditDigestVerifier, got %T", mode, site, v)
			}
			if err := v.VerifyDigest(context.Background(), "/cache/m.erofs", "sha256:aa"); err != nil {
				t.Fatalf("mode %s at %s: measure-only fs-verity must never refuse a mount: %v", mode, site, err)
			}
			if len(reported) != 1 || !strings.HasPrefix(reported[0], "verify:module_fsverity_audit: ") ||
				!strings.Contains(reported[0], "/cache/m.erofs") || !strings.Contains(reported[0], "fsverity") {
				t.Fatalf("mode %s at %s: the would-be refusal must be reported with the blob path: %v", mode, site, reported)
			}
		}
	}
}

func TestNewModuleFsverityRejectsUnknownMode(t *testing.T) {
	if _, err := NewModuleFsverity(ModuleSigningConfig{Mode: "enforce"}, SiteService, nil, nil); err == nil {
		t.Fatal("an unknown mode must be refused, never coerced")
	}
}

func TestAuditDigestVerifierStaysQuietOnSuccess(t *testing.T) {
	var reported int
	a := AuditDigestVerifier{Inner: digestVerifierFunc(func(context.Context, string, string) error { return nil }),
		Report: func(string, error) { reported++ }}
	if err := a.VerifyDigest(context.Background(), "/b", "sha256:aa"); err != nil {
		t.Fatal(err)
	}
	if reported != 0 {
		t.Fatalf("nothing to report on success, got %d reports", reported)
	}
}

// A module published with no fsverity_root_hash is named as such, so the
// measurement tells the operator the fix is on the publish side. The runner
// must not be touched: there is nothing to compare against.
func TestFsVerifierNamesAMissingRootWithoutRunningFsverity(t *testing.T) {
	runner := &mount.RecorderRunner{}
	err := (&FsVerifier{Runner: runner}).VerifyDigest(context.Background(), "/b", "")
	if err == nil || !strings.Contains(err.Error(), "no fsverity_root_hash published") {
		t.Fatalf("want a missing-root error naming fsverity_root_hash, got %v", err)
	}
	if len(runner.Invocations) != 0 {
		t.Fatalf("fsverity must not run without an expected root: %+v", runner.Invocations)
	}
}

// fsverity-utils reports enable failures as strerror text inside the runner's
// error, not as errno names. An unsupported filesystem (plain ext4 /persist)
// or an already-enabled blob must still fall through to the userspace digest,
// or the measurement reports every mount forever and can never go quiet.
func TestFsVerifierToleratesStrerrorEnableFailuresAndStillDigests(t *testing.T) {
	for _, out := range []string{"Operation not supported", "File exists"} {
		runner := &mount.RecorderRunner{
			StubErr: map[string]error{
				"fsverity enable /b": errors.New("fsverity [enable /b]: exit status 1 (output: ERROR: FS_IOC_ENABLE_VERITY failed on '/b': " + out + ")"),
			},
			StubOutput: map[string][]byte{
				"fsverity digest --hash-alg sha256 /b": []byte("sha256:aa /b\n"),
			},
		}
		if err := (&FsVerifier{Runner: runner}).VerifyDigest(context.Background(), "/b", "sha256:aa"); err != nil {
			t.Fatalf("%q: an enable failure of this kind must fall through to the digest: %v", out, err)
		}
		if len(runner.Invocations) != 2 {
			t.Fatalf("%q: want enable then digest, got %+v", out, runner.Invocations)
		}
	}
}

func TestFsVerifierSurfacesUnexpectedEnableFailures(t *testing.T) {
	runner := &mount.RecorderRunner{StubErr: map[string]error{
		"fsverity enable /b": errors.New(`exec: "fsverity": executable file not found in $PATH`),
	}}
	if err := (&FsVerifier{Runner: runner}).VerifyDigest(context.Background(), "/b", "sha256:aa"); err == nil {
		t.Fatal("a missing binary is not a tolerable enable failure")
	}
}

type digestVerifierFunc func(ctx context.Context, path, expected string) error

func (f digestVerifierFunc) VerifyDigest(ctx context.Context, path, expected string) error {
	return f(ctx, path, expected)
}
