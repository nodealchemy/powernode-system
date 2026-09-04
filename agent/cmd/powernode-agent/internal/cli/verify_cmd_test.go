package cli

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

func writeVerifyFixture(t *testing.T) (module, bundle string) {
	t.Helper()
	dir := t.TempDir()
	module = filepath.Join(dir, "mod.erofs")
	bundle = module + ".cosign-bundle"
	for _, p := range []string{module, bundle} {
		if err := os.WriteFile(p, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return module, bundle
}

// --key must reach cosign with EXACTLY the argv shape the runtime's
// static-key verifier uses (verify.CosignVerifier: --key K --bundle B
// --insecure-ignore-tlog=true BLOB). A CLI that verified differently could
// green-light what an enforcing node rejects, which is worse than no CLI.
func TestRunVerifyWithKeyUsesTheRuntimeStaticKeyPath(t *testing.T) {
	module, bundle := writeVerifyFixture(t)
	runner := &mount.RecorderRunner{}
	res, err := RunVerify(context.Background(), VerifyOptions{
		ModulePath: module,
		KeyPaths:   []string{"/persist/k/a.pub"},
		Runner:     runner,
	})
	if err != nil {
		t.Fatalf("RunVerify: %v (%+v)", err, res.Details)
	}
	var cosign []mount.Invocation
	for _, inv := range runner.Invocations {
		if inv.Name == "cosign" {
			cosign = append(cosign, inv)
		}
	}
	if len(cosign) != 1 {
		t.Fatalf("want exactly one cosign invocation, got %+v", runner.Invocations)
	}
	want := "verify-blob --key /persist/k/a.pub --bundle " + bundle + " --insecure-ignore-tlog=true " + module
	if got := strings.Join(cosign[0].Args, " "); got != want {
		t.Fatalf("cosign argv:\n got %s\nwant %s", got, want)
	}
	if res.Details["trust"] != "static-key" {
		t.Fatalf("result must say which trust anchor verified: %+v", res.Details)
	}
}

// --key-dir trusts every *.pub in the directory — the shape of the runtime's
// platform-key cache under /persist — so an operator can re-verify against
// exactly what the node trusts.
func TestRunVerifyKeyDirTrustsEveryPubFile(t *testing.T) {
	module, _ := writeVerifyFixture(t)
	keyDir := t.TempDir()
	for _, n := range []string{"aaaa.pub", "bbbb.pub", "notes.txt"} {
		_ = os.WriteFile(filepath.Join(keyDir, n), []byte("k"), 0o644)
	}
	runner := &mount.RecorderRunner{StubErr: map[string]error{}}
	// Make the first key fail so the second is tried.
	first := filepath.Join(keyDir, "aaaa.pub")
	runner.StubErr["cosign verify-blob --key "+first+" --bundle "+module+".cosign-bundle --insecure-ignore-tlog=true "+module] = os.ErrInvalid
	if _, err := RunVerify(context.Background(), VerifyOptions{ModulePath: module, KeyDir: keyDir, Runner: runner}); err != nil {
		t.Fatalf("second key should verify: %v", err)
	}
	var keys []string
	for _, inv := range runner.Invocations {
		if inv.Name == "cosign" {
			keys = append(keys, inv.Args[2])
		}
	}
	if strings.Join(keys, ",") != first+","+filepath.Join(keyDir, "bbbb.pub") {
		t.Fatalf("keys tried: %v", keys)
	}
}

func TestRunVerifyRefusesWithoutAnyTrustAnchor(t *testing.T) {
	module, _ := writeVerifyFixture(t)
	res, err := RunVerify(context.Background(), VerifyOptions{ModulePath: module, Runner: &mount.RecorderRunner{}})
	if err == nil || res.ExitCode == ExitOK {
		t.Fatalf("no --key and no keyless pins must not verify: %+v", res)
	}
}
