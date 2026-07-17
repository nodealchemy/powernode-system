package runtime

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
)

// mkComposeRoots makes <dir>/sysroot and <dir>/persist so
// applyTraefikIngressPersistence has somewhere to land, and returns both.
func mkComposeRoots(t *testing.T) (sysroot, persistRoot string) {
	t.Helper()
	dir := t.TempDir()
	sysroot = filepath.Join(dir, "sysroot")
	persistRoot = filepath.Join(dir, "persist")
	if err := os.MkdirAll(sysroot, 0o755); err != nil {
		t.Fatalf("mkdir sysroot: %v", err)
	}
	return sysroot, persistRoot
}

func noopOnErr(t *testing.T) func(string, error) {
	t.Helper()
	return func(stage string, err error) {
		t.Fatalf("unexpected onErr(%q, %v)", stage, err)
	}
}

func withTraefik() map[string]*manifest.Manifest {
	return map[string]*manifest.Manifest{
		"reverse-proxy-traefik": {ID: "reverse-proxy-traefik"},
	}
}

func TestApplyTraefikIngressPersistence_NoOpWithoutTraefikModule(t *testing.T) {
	sysroot, persistRoot := mkComposeRoots(t)

	applyTraefikIngressPersistence(sysroot, persistRoot, map[string]*manifest.Manifest{}, noopOnErr(t))

	if _, err := os.Stat(filepath.Join(sysroot, "etc", "traefik")); !os.IsNotExist(err) {
		t.Fatalf("expected no /etc/traefik to be created when reverse-proxy-traefik isn't composed, stat err = %v", err)
	}
}

func TestApplyTraefikIngressPersistence_SymlinksDynamicAndCerts(t *testing.T) {
	sysroot, persistRoot := mkComposeRoots(t)

	applyTraefikIngressPersistence(sysroot, persistRoot, withTraefik(), noopOnErr(t))

	for _, sub := range []string{"dynamic", "certs"} {
		link := filepath.Join(sysroot, "etc", "traefik", sub)
		target := filepath.Join(persistRoot, sub)

		got, err := os.Readlink(link)
		if err != nil {
			t.Fatalf("readlink %s: %v", link, err)
		}
		if got != target {
			t.Fatalf("%s -> %q, want %q", link, got, target)
		}
		if fi, err := os.Stat(target); err != nil || !fi.IsDir() {
			t.Fatalf("expected persist target %s to be a real directory, stat = %v, err = %v", target, fi, err)
		}
	}
}

func TestApplyTraefikIngressPersistence_ReplacesRealLowerLayerDir(t *testing.T) {
	sysroot, persistRoot := mkComposeRoots(t)

	// Simulate the reverse-proxy-traefik module's own baked lower-layer
	// content: a real (empty) directory already present at
	// etc/traefik/dynamic (stage15.sh's `mkdir -p .../etc/traefik/dynamic`),
	// with a stray file inside it (as if union-carved content landed there)
	// — the pre-swap state this function must replace, not merge into.
	dynamicDir := filepath.Join(sysroot, "etc", "traefik", "dynamic")
	if err := os.MkdirAll(dynamicDir, 0o755); err != nil {
		t.Fatalf("seed dynamic dir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dynamicDir, "stale.yaml"), []byte("stale"), 0o644); err != nil {
		t.Fatalf("seed stale file: %v", err)
	}

	applyTraefikIngressPersistence(sysroot, persistRoot, withTraefik(), noopOnErr(t))

	link := filepath.Join(sysroot, "etc", "traefik", "dynamic")
	fi, err := os.Lstat(link)
	if err != nil {
		t.Fatalf("lstat %s: %v", link, err)
	}
	if fi.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("expected %s to be a symlink after replacing the baked lower-layer dir, mode = %v", link, fi.Mode())
	}
}

func TestApplyTraefikIngressPersistence_IdempotentOnRepeatedCompose(t *testing.T) {
	sysroot, persistRoot := mkComposeRoots(t)

	applyTraefikIngressPersistence(sysroot, persistRoot, withTraefik(), noopOnErr(t))
	// A second compose (e.g. a re-run before switch_root) must not fail or
	// churn an already-correct symlink.
	applyTraefikIngressPersistence(sysroot, persistRoot, withTraefik(), noopOnErr(t))

	link := filepath.Join(sysroot, "etc", "traefik", "dynamic")
	got, err := os.Readlink(link)
	if err != nil {
		t.Fatalf("readlink %s: %v", link, err)
	}
	if want := filepath.Join(persistRoot, "dynamic"); got != want {
		t.Fatalf("%s -> %q, want %q", link, got, want)
	}
}

func TestApplyTraefikIngressPersistence_PreservesExistingPersistedConfig(t *testing.T) {
	sysroot, persistRoot := mkComposeRoots(t)

	// Simulate a prior boot having already written durable dynamic config —
	// this file must survive a fresh compose (the whole point of the fix).
	priorDynamic := filepath.Join(persistRoot, "dynamic")
	if err := os.MkdirAll(priorDynamic, 0o755); err != nil {
		t.Fatalf("seed persisted dynamic dir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(priorDynamic, "acme-1.yaml"), []byte("router: config"), 0o644); err != nil {
		t.Fatalf("seed persisted config: %v", err)
	}

	applyTraefikIngressPersistence(sysroot, persistRoot, withTraefik(), noopOnErr(t))

	got, err := os.ReadFile(filepath.Join(sysroot, "etc", "traefik", "dynamic", "acme-1.yaml"))
	if err != nil {
		t.Fatalf("read through symlink: %v", err)
	}
	if string(got) != "router: config" {
		t.Fatalf("config = %q, want %q (prior boot's config must survive)", string(got), "router: config")
	}
}
