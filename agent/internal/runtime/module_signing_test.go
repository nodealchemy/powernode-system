package runtime

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/oci"
	"github.com/nodealchemy/powernode-system/agent/internal/verify"
)

// --- config resolution -------------------------------------------------------

func TestLoadModuleSigningConfigDefaultsOff(t *testing.T) {
	cfg, err := LoadModuleSigningConfig(func(string) string { return "" }, filepath.Join(t.TempDir(), "absent.conf"))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Active() {
		t.Fatalf("no env, no conf file must mean OFF, got %+v", cfg)
	}
}

func TestLoadModuleSigningConfigReadsConfThenEnvOverrides(t *testing.T) {
	conf := filepath.Join(t.TempDir(), "module-signing.conf")
	if err := os.WriteFile(conf, []byte("# operator opt-in\nMODE=audit\nKEYS=/persist/k/a.pub:/persist/k/b.pub\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg, err := LoadModuleSigningConfig(func(string) string { return "" }, conf)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Mode != verify.ModeAudit || len(cfg.KeyPaths) != 2 || cfg.KeyPaths[1] != "/persist/k/b.pub" {
		t.Fatalf("conf file not honoured: %+v", cfg)
	}

	env := map[string]string{"POWERNODE_MODULE_SIGNING_MODE": "runtime"}
	cfg, err = LoadModuleSigningConfig(func(k string) string { return env[k] }, conf)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Mode != verify.ModeRuntime || len(cfg.KeyPaths) != 2 {
		t.Fatalf("env MODE must override the file and leave the file's KEYS: %+v", cfg)
	}

	env["POWERNODE_MODULE_SIGNING_KEYS"] = "/etc/only.pub"
	cfg, _ = LoadModuleSigningConfig(func(k string) string { return env[k] }, conf)
	if len(cfg.KeyPaths) != 1 || cfg.KeyPaths[0] != "/etc/only.pub" {
		t.Fatalf("env KEYS must override the file's KEYS: %+v", cfg)
	}
}

func TestLoadModuleSigningConfigRejectsUnknownMode(t *testing.T) {
	conf := filepath.Join(t.TempDir(), "module-signing.conf")
	_ = os.WriteFile(conf, []byte("MODE=enforce\n"), 0o644)
	if _, err := LoadModuleSigningConfig(func(string) string { return "" }, conf); err == nil {
		t.Fatal("an unknown mode in the conf file must be an error, not off and not all")
	}
}

// --- trust-anchor cache --------------------------------------------------------

func TestCachePlatformSigningKeysWritesAndPrunes(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "platform-keys")
	stale := filepath.Join(dir, "stale.pub")
	_ = os.MkdirAll(dir, 0o700)
	_ = os.WriteFile(stale, []byte("old"), 0o644)

	pems := []string{"-----BEGIN PUBLIC KEY-----\nAAA\n-----END PUBLIC KEY-----\n", "-----BEGIN PUBLIC KEY-----\nBBB\n-----END PUBLIC KEY-----\n"}
	paths, err := cachePlatformSigningKeys(dir, pems)
	if err != nil {
		t.Fatal(err)
	}
	if len(paths) != 2 {
		t.Fatalf("paths: %v", paths)
	}
	for i, p := range paths {
		got, err := os.ReadFile(p)
		if err != nil || string(got) != pems[i] {
			t.Fatalf("key %d not written verbatim: %v %q", i, err, got)
		}
	}
	if _, err := os.Stat(stale); !os.IsNotExist(err) {
		t.Fatal("a key the platform no longer trusts must be pruned from the cache")
	}
	// Idempotent: same input, same paths, still two files.
	again, _ := cachePlatformSigningKeys(dir, pems)
	if strings.Join(again, ",") != strings.Join(paths, ",") {
		t.Fatalf("cache paths must be content-addressed and stable: %v vs %v", again, paths)
	}
	if got, _ := cachedPlatformSigningKeys(dir); len(got) != 2 {
		t.Fatalf("cachedPlatformSigningKeys: %v", got)
	}
}

// --- verifier resolution --------------------------------------------------------

type signingKeysStub struct {
	body  string
	err   error
	calls int
}

func (s *signingKeysStub) GetJSON(path string) (*http.Response, error) {
	s.calls++
	if path != "/api/v1/system/node_api/modules/signing_keys" {
		return nil, errors.New("unexpected path " + path)
	}
	if s.err != nil {
		return nil, s.err
	}
	return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(s.body))}, nil
}

const twoKeysBody = `{"success":true,"data":{"keys":["-----BEGIN PUBLIC KEY-----\nAAA\n-----END PUBLIC KEY-----\n","-----BEGIN PUBLIC KEY-----\nBBB\n-----END PUBLIC KEY-----\n"],"count":2}}`

func TestResolveModuleVerifierOffNeverTouchesTheNetwork(t *testing.T) {
	c := &signingKeysStub{err: errors.New("must not be called")}
	v, err := ResolveModuleVerifier(verify.ModuleSigningConfig{}, verify.SiteService, c, &mount.RecorderRunner{}, t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := v.(verify.AlwaysOK); !ok || c.calls != 0 {
		t.Fatalf("off must be AlwaysOK with zero fetches: %T calls=%d", v, c.calls)
	}
}

func TestResolveModuleVerifierPinnedKeysSkipTheFetch(t *testing.T) {
	c := &signingKeysStub{err: errors.New("must not be called")}
	v, err := ResolveModuleVerifier(verify.ModuleSigningConfig{Mode: verify.ModeAll, KeyPaths: []string{"/persist/k/a.pub"}},
		verify.SiteService, c, &mount.RecorderRunner{}, t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	cv, ok := v.(*verify.CosignVerifier)
	if !ok || c.calls != 0 || len(cv.KeyPaths) != 1 {
		t.Fatalf("pinned keys must be used as-is with no fetch: %T calls=%d", v, c.calls)
	}
}

func TestResolveModuleVerifierFetchesAndCachesPlatformKeys(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "keys")
	c := &signingKeysStub{body: twoKeysBody}
	v, err := ResolveModuleVerifier(verify.ModuleSigningConfig{Mode: verify.ModeRuntime}, verify.SiteService, c, &mount.RecorderRunner{}, dir, nil)
	if err != nil {
		t.Fatal(err)
	}
	cv, ok := v.(*verify.CosignVerifier)
	if !ok {
		t.Fatalf("runtime mode at the service site must ENFORCE: got %T", v)
	}
	if len(cv.KeyPaths) != 2 {
		t.Fatalf("both platform keys must be trusted: %v", cv.KeyPaths)
	}
	for _, p := range cv.KeyPaths {
		if !strings.HasPrefix(p, dir) {
			t.Fatalf("key path %s must live under the cache dir %s", p, dir)
		}
		if b, err := os.ReadFile(p); err != nil || !strings.Contains(string(b), "BEGIN PUBLIC KEY") {
			t.Fatalf("cached key unreadable: %v %q", err, b)
		}
	}
}

func TestResolveModuleVerifierFallsBackToCachedKeysWhenFetchFails(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "keys")
	if _, err := cachePlatformSigningKeys(dir, []string{"-----BEGIN PUBLIC KEY-----\nOLD\n-----END PUBLIC KEY-----\n"}); err != nil {
		t.Fatal(err)
	}
	var reported []string
	c := &signingKeysStub{err: errors.New("platform unreachable")}
	v, err := ResolveModuleVerifier(verify.ModuleSigningConfig{Mode: verify.ModeAll}, verify.SiteBoot, c, &mount.RecorderRunner{}, dir,
		func(stage string, err error) { reported = append(reported, stage) })
	if err != nil {
		t.Fatalf("a cached trust anchor must carry an offline boot: %v", err)
	}
	if cv, ok := v.(*verify.CosignVerifier); !ok || len(cv.KeyPaths) != 1 {
		t.Fatalf("want the cached key, got %T", v)
	}
	if len(reported) != 1 || reported[0] != "verify:module_signing_keys" {
		t.Fatalf("the failed refresh must be reported, not hidden: %v", reported)
	}
}

func TestResolveModuleVerifierEnforcingWithNoKeysFailsClosed(t *testing.T) {
	c := &signingKeysStub{err: errors.New("platform unreachable")}
	_, err := ResolveModuleVerifier(verify.ModuleSigningConfig{Mode: verify.ModeAll}, verify.SiteService, c, &mount.RecorderRunner{}, filepath.Join(t.TempDir(), "empty"), nil)
	if err == nil || !strings.Contains(err.Error(), "no trusted public key") {
		t.Fatalf("enforcing with no anchor must refuse to construct: %v", err)
	}
}

// Non-enforcing sites (audit anywhere; the boot composer under runtime) must
// never be BLOCKED by a missing anchor — they degrade to AlwaysOK and say so.
func TestResolveModuleVerifierNonEnforcingWithNoKeysDegradesLoudly(t *testing.T) {
	var reported []string
	c := &signingKeysStub{err: errors.New("platform unreachable")}
	for _, tc := range []struct {
		mode string
		site verify.Site
	}{{verify.ModeAudit, verify.SiteService}, {verify.ModeRuntime, verify.SiteBoot}} {
		reported = nil
		v, err := ResolveModuleVerifier(verify.ModuleSigningConfig{Mode: tc.mode}, tc.site, c, &mount.RecorderRunner{}, filepath.Join(t.TempDir(), "empty"),
			func(stage string, err error) { reported = append(reported, stage) })
		if err != nil {
			t.Fatalf("%s/%s: must not block: %v", tc.mode, tc.site, err)
		}
		if _, ok := v.(verify.AlwaysOK); !ok {
			t.Fatalf("%s/%s: want AlwaysOK degrade, got %T", tc.mode, tc.site, v)
		}
		if len(reported) == 0 {
			t.Fatalf("%s/%s: the degrade must be reported", tc.mode, tc.site)
		}
	}
}

// --- bundle threading: manifest -> mount.Module -> Puller ref ------------------

type refCapturingPuller struct {
	mu   sync.Mutex
	refs []*oci.ModuleArtifactRef
	dir  string
}

func (p *refCapturingPuller) Pull(ref *oci.ModuleArtifactRef) (string, string, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.refs = append(p.refs, ref)
	digestFs := strings.ReplaceAll(ref.Digest, ":", "_")
	_ = os.MkdirAll(p.dir, 0o755)
	erofs := filepath.Join(p.dir, digestFs+".erofs")
	_ = os.WriteFile(erofs, []byte("blob"), 0o644)
	return erofs, filepath.Join(p.dir, digestFs+".cosign-bundle"), nil
}

// The bundle rides the manifest exactly as the fs-verity root does. This
// drives a whole tick so every hop is exercised: modules#show carries
// cosign_bundle_b64 -> manifest.Manifest -> mount.Module -> the ref handed to
// Puller.Pull, which is what materialises the bundle for the verifier.
func TestReconcileThreadsManifestCosignBundleIntoThePullRef(t *testing.T) {
	tmpRoot := t.TempDir()
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())
	client := &stubModulesClient{responses: map[string]string{
		"/api/v1/system/node_api/modules": `{"success":true,"data":{"modules":[
			{"id":"m1","name":"nginx","priority":100,"effective_priority":100,"has_data_file":true}]}}`,
		"/api/v1/system/node_api/modules/m1": `{"success":true,"data":{"id":"m1","name":"nginx",
			"priority":100,"effective_priority":100,"digest":"sha256:abc123",
			"cosign_bundle_b64":"eyJwcmV0ZW5kIjoiYnVuZGxlIn0=",
			"services":[{"name":"nginx","start_command":"/usr/sbin/nginx","restart_policy":"always"}]}}`,
	}}
	layout := mount.DefaultLayout()
	layout.Root = tmpRoot
	layout = layout.Resolve()
	puller := &refCapturingPuller{dir: layout.ModulesCacheRoot}
	r, err := NewReconciler(ReconcilerConfig{
		ModulesClient: client, ManifestClient: client,
		ManifestRoot: filepath.Join(tmpRoot, "manifests"),
		Puller:       puller, Verifier: verify.AlwaysOK{},
		MountRunner: &mount.RecorderRunner{}, Layout: layout,
		StatePath: filepath.Join(tmpRoot, "state.json"),
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}
	if len(puller.refs) == 0 {
		t.Fatal("puller was never called")
	}
	for _, ref := range puller.refs {
		if ref.CosignBundleB64 != "eyJwcmV0ZW5kIjoiYnVuZGxlIn0=" {
			t.Fatalf("the manifest's cosign_bundle_b64 did not reach the pull ref: %+v", ref)
		}
	}
}

func TestLKGCosignBundleRidesTheFrozenManifest(t *testing.T) {
	m := LKGModule{ID: "m", Digest: "sha256:aa", Manifest: json.RawMessage(`{"digest":"sha256:aa","cosign_bundle_b64":"YnVuZGxl"}`)}
	if got := lkgCosignBundle(m); got != "YnVuZGxl" {
		t.Fatalf("lkgCosignBundle = %q", got)
	}
	if got := lkgCosignBundle(LKGModule{ID: "m"}); got != "" {
		t.Fatalf("absent manifest must yield no bundle, got %q", got)
	}
}
