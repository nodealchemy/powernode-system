package verify

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// writeTempFile creates a throwaway file so the bundle-presence check has
// something to stat. The CONTENT is irrelevant: every test here drives the
// verifier through a RecorderRunner, so cosign itself never runs.
func writeTempFile(t *testing.T, name string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(p, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestCosignVerifierTriesEachKeyPathInOrderAndStopsAtFirstSuccess(t *testing.T) {
	bundle := writeTempFile(t, "m.cosign-bundle")
	blob := writeTempFile(t, "m.erofs")
	runner := &mount.RecorderRunner{StubErr: map[string]error{
		"cosign verify-blob --key /k/old.pub --bundle " + bundle + " --insecure-ignore-tlog=true " + blob: errors.New("no match"),
	}}
	v := &CosignVerifier{Runner: runner, KeyPaths: []string{"/k/old.pub", "/k/new.pub", "/k/never.pub"}}
	if err := v.VerifyBlob(context.Background(), blob, bundle); err != nil {
		t.Fatalf("second key should have verified: %v", err)
	}
	if got := len(runner.Invocations); got != 2 {
		t.Fatalf("invocations: got %d, want 2 (old fails, new succeeds, never is not tried)", got)
	}
	if !strings.Contains(strings.Join(runner.Invocations[1].Args, " "), "--key /k/new.pub") {
		t.Fatalf("second invocation did not use the second key: %v", runner.Invocations[1].Args)
	}
}

func TestCosignVerifierFailsClosedWhenNoKeyVerifies(t *testing.T) {
	bundle := writeTempFile(t, "m.cosign-bundle")
	blob := writeTempFile(t, "m.erofs")
	runner := &mount.RecorderRunner{StubErr: map[string]error{
		"cosign verify-blob --key /k/a.pub --bundle " + bundle + " --insecure-ignore-tlog=true " + blob: errors.New("bad sig a"),
		"cosign verify-blob --key /k/b.pub --bundle " + bundle + " --insecure-ignore-tlog=true " + blob: errors.New("bad sig b"),
	}}
	v := &CosignVerifier{Runner: runner, KeyPaths: []string{"/k/a.pub", "/k/b.pub"}}
	err := v.VerifyBlob(context.Background(), blob, bundle)
	if err == nil {
		t.Fatal("expected failure when no trusted key verifies the bundle")
	}
	if !strings.Contains(err.Error(), "2 trusted key(s)") {
		t.Fatalf("error should say how many keys were tried: %v", err)
	}
}

// KeyPath (singular, the boot-upgrade path's field) keeps working and is
// tried before KeyPaths, so bootupgrade's construction is byte-identical.
func TestCosignVerifierKeyPathIsTriedFirst(t *testing.T) {
	bundle := writeTempFile(t, "m.cosign-bundle")
	blob := writeTempFile(t, "m.erofs")
	runner := &mount.RecorderRunner{}
	v := &CosignVerifier{Runner: runner, KeyPath: "/k/single.pub", KeyPaths: []string{"/k/extra.pub"}}
	if err := v.VerifyBlob(context.Background(), blob, bundle); err != nil {
		t.Fatal(err)
	}
	if len(runner.Invocations) != 1 || !strings.Contains(strings.Join(runner.Invocations[0].Args, " "), "--key /k/single.pub") {
		t.Fatalf("KeyPath must be tried first and alone on success: %+v", runner.Invocations)
	}
}

// A bundle path the puller constructed but never materialised — the exact
// shape a module with no platform blob signature presents — must be refused
// BEFORE cosign runs, with an error that names the real cause. Refusing on
// cosign's own "open: no such file" would be correct but opaque.
func TestCosignVerifierStaticKeyRefusesMissingBundleBeforeRunningCosign(t *testing.T) {
	blob := writeTempFile(t, "m.erofs")
	runner := &mount.RecorderRunner{}
	v := &CosignVerifier{Runner: runner, KeyPaths: []string{"/k/a.pub"}}
	err := v.VerifyBlob(context.Background(), blob, filepath.Join(t.TempDir(), "absent.cosign-bundle"))
	if err == nil {
		t.Fatal("expected an error for a missing bundle")
	}
	if !strings.Contains(err.Error(), "no cosign bundle") {
		t.Fatalf("error should name the missing bundle: %v", err)
	}
	if len(runner.Invocations) != 0 {
		t.Fatalf("cosign must not run without a bundle: %+v", runner.Invocations)
	}
}

func TestAuditVerifierReportsButNeverRefuses(t *testing.T) {
	var reported []string
	inner := failingVerifier{err: errors.New("untrusted")}
	a := AuditVerifier{Inner: inner, Report: func(stage string, err error) {
		reported = append(reported, stage+": "+err.Error())
	}}
	if err := a.VerifyBlob(context.Background(), "/b", "/s"); err != nil {
		t.Fatalf("audit mode must not refuse: %v", err)
	}
	if len(reported) != 1 || !strings.Contains(reported[0], "untrusted") || !strings.Contains(reported[0], "/b") {
		t.Fatalf("audit mode must report the would-be refusal with the blob path: %v", reported)
	}
}

func TestAuditVerifierStaysQuietOnSuccess(t *testing.T) {
	var reported int
	a := AuditVerifier{Inner: AlwaysOK{}, Report: func(string, error) { reported++ }}
	if err := a.VerifyBlob(context.Background(), "/b", "/s"); err != nil {
		t.Fatal(err)
	}
	if reported != 0 {
		t.Fatalf("nothing to report on success, got %d reports", reported)
	}
}

type failingVerifier struct{ err error }

func (f failingVerifier) VerifyBlob(context.Context, string, string) error { return f.err }

// DEFAULT OFF. The zero config — and every explicit "off" — yields the no-op
// verifier at every site, with no keys required and no report hook consulted.
// This is the property the operator runbook depends on: a node that has not
// opted in behaves exactly as before this capability existed.
func TestNewModuleVerifierDefaultsToAlwaysOKAtEverySite(t *testing.T) {
	for _, cfg := range []ModuleSigningConfig{{}, {Mode: ModeOff}, {Mode: ModeOff, KeyPaths: []string{"/k/a.pub"}}} {
		for _, site := range []Site{SiteService, SiteCLI, SiteBoot} {
			v, err := NewModuleVerifier(cfg, site, &mount.RecorderRunner{}, nil)
			if err != nil {
				t.Fatalf("cfg %+v site %s: %v", cfg, site, err)
			}
			if _, ok := v.(AlwaysOK); !ok {
				t.Fatalf("cfg %+v site %s: want AlwaysOK, got %T", cfg, site, v)
			}
		}
	}
}

func TestNewModuleVerifierRejectsUnknownMode(t *testing.T) {
	if _, err := NewModuleVerifier(ModuleSigningConfig{Mode: "yes"}, SiteService, &mount.RecorderRunner{}, nil); err == nil {
		t.Fatal("an unknown mode must be refused, not silently treated as off or as enforce")
	}
}

// Every mode past off needs a trust anchor. Refusing here — rather than
// returning a verifier that fails on every blob — surfaces the misconfiguration
// at construction, where the reconciler/service reports it once, instead of on
// every mount.
func TestNewModuleVerifierRequiresKeysPastOff(t *testing.T) {
	for _, mode := range []string{ModeAudit, ModeRuntime, ModeAll} {
		_, err := NewModuleVerifier(ModuleSigningConfig{Mode: mode}, SiteService, &mount.RecorderRunner{}, nil)
		if err == nil || !strings.Contains(err.Error(), "no trusted public key") {
			t.Fatalf("mode %s without keys: want a no-trust-anchor error, got %v", mode, err)
		}
	}
}

func TestNewModuleVerifierEnforcementLadder(t *testing.T) {
	keys := []string{"/k/a.pub"}
	report := func(string, error) {}
	cases := []struct {
		mode string
		site Site
		want string // "cosign" (enforcing) | "audit"
	}{
		{ModeAudit, SiteService, "audit"},
		{ModeAudit, SiteCLI, "audit"},
		{ModeAudit, SiteBoot, "audit"},
		{ModeRuntime, SiteService, "cosign"},
		{ModeRuntime, SiteCLI, "cosign"},
		{ModeRuntime, SiteBoot, "audit"}, // the boot composer's blast radius is an unbootable node
		{ModeAll, SiteService, "cosign"},
		{ModeAll, SiteCLI, "cosign"},
		{ModeAll, SiteBoot, "cosign"},
	}
	for _, c := range cases {
		v, err := NewModuleVerifier(ModuleSigningConfig{Mode: c.mode, KeyPaths: keys}, c.site, &mount.RecorderRunner{}, report)
		if err != nil {
			t.Fatalf("%s/%s: %v", c.mode, c.site, err)
		}
		switch c.want {
		case "cosign":
			cv, ok := v.(*CosignVerifier)
			if !ok {
				t.Fatalf("%s/%s: want *CosignVerifier, got %T", c.mode, c.site, v)
			}
			if len(cv.KeyPaths) != 1 || cv.KeyPaths[0] != "/k/a.pub" {
				t.Fatalf("%s/%s: keys not threaded: %+v", c.mode, c.site, cv.KeyPaths)
			}
		case "audit":
			av, ok := v.(AuditVerifier)
			if !ok {
				t.Fatalf("%s/%s: want AuditVerifier, got %T", c.mode, c.site, v)
			}
			if _, ok := av.Inner.(*CosignVerifier); !ok {
				t.Fatalf("%s/%s: audit must wrap the REAL verifier, got %T", c.mode, c.site, av.Inner)
			}
		}
	}
}

func TestModuleSigningConfigEnforces(t *testing.T) {
	if (ModuleSigningConfig{Mode: ModeRuntime}).Enforces(SiteBoot) {
		t.Fatal("runtime mode must not enforce on the boot composer")
	}
	if !(ModuleSigningConfig{Mode: ModeAll}).Enforces(SiteBoot) {
		t.Fatal("all mode must enforce on the boot composer")
	}
	if (ModuleSigningConfig{Mode: ModeAudit}).Enforces(SiteService) {
		t.Fatal("audit never enforces")
	}
	if (ModuleSigningConfig{}).Active() || !(ModuleSigningConfig{Mode: ModeAudit}).Active() {
		t.Fatal("Active must be false for off and true for any other mode")
	}
}
