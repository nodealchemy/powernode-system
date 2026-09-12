package runtime

import (
	"context"
	"path/filepath"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/verify"
)

// IMP-4eabe61c3d90 — the fs-verity arm, resolved through the same policy as
// the signature arm at every module-mount site.

// DEFAULT OFF: the zero policy wires no fs-verity check anywhere, so a node that
// has not opted in mounts exactly as before.
func TestResolveModuleFsverityDefaultIsNoCheckAtEverySite(t *testing.T) {
	for _, site := range []verify.Site{verify.SiteService, verify.SiteCLI, verify.SiteBoot} {
		v, err := ResolveModuleFsverity(verify.ModuleSigningConfig{}, site, &mount.RecorderRunner{}, nil)
		if err != nil {
			t.Fatalf("%s: %v", site, err)
		}
		if v != nil {
			t.Fatalf("%s: default must wire no fs-verity check, got %T", site, v)
		}
	}
}

// End to end through a whole tick: under an active mode, a module published
// with no fsverity_root_hash is REPORTED and still mounted. Before this arm was
// resolvable the reconciler's own empty-root branch refused the mount outright
// whenever Fsverity was set, which is why no site could ever set it.
func TestReconcileMeasuresAMissingFsverityRootWithoutRefusingTheMount(t *testing.T) {
	tmpRoot := t.TempDir()
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())
	client := &stubModulesClient{responses: map[string]string{
		"/api/v1/system/node_api/modules": `{"success":true,"data":{"modules":[
			{"id":"m1","name":"nginx","priority":100,"effective_priority":100,"has_data_file":true}]}}`,
		"/api/v1/system/node_api/modules/m1": `{"success":true,"data":{"id":"m1","name":"nginx",
			"priority":100,"effective_priority":100,"digest":"sha256:abc123",
			"services":[{"name":"nginx","start_command":"/usr/sbin/nginx","restart_policy":"always"}]}}`,
	}}
	layout := mount.DefaultLayout()
	layout.Root = tmpRoot
	layout = layout.Resolve()
	puller := &refCapturingPuller{dir: layout.ModulesCacheRoot}

	var reports []string
	onError := func(stage string, err error) { reports = append(reports, stage+": "+err.Error()) }
	fsRunner := &mount.RecorderRunner{}
	fsv, err := ResolveModuleFsverity(verify.ModuleSigningConfig{Mode: verify.ModeRuntime}, verify.SiteService, fsRunner, onError)
	if err != nil {
		t.Fatal(err)
	}
	mountRunner := &mount.RecorderRunner{}
	r, err := NewReconciler(ReconcilerConfig{
		ModulesClient: client, ManifestClient: client,
		ManifestRoot: filepath.Join(tmpRoot, "manifests"),
		Puller:       puller, Verifier: verify.AlwaysOK{}, Fsverity: fsv,
		MountRunner: mountRunner, Layout: layout,
		StatePath: filepath.Join(tmpRoot, "state.json"),
		OnError:   onError,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce refused under measure-only fs-verity: %v", err)
	}

	var measured bool
	for _, rep := range reports {
		if strings.HasPrefix(rep, "verify:module_fsverity_audit: ") && strings.Contains(rep, "no fsverity_root_hash published") {
			measured = true
		}
		if strings.Contains(rep, "verify fs-verity") {
			t.Fatalf("the missing root was refused, not measured: %v", reports)
		}
	}
	if !measured {
		t.Fatalf("the missing root must be reported under verify:module_fsverity_audit, got %v", reports)
	}
	var mounted bool
	for _, inv := range mountRunner.Invocations {
		if inv.Name == "mount" {
			mounted = true
		}
	}
	if !mounted {
		t.Fatalf("the module must still be mounted; runner saw %+v", mountRunner.Invocations)
	}
	if len(fsRunner.Invocations) != 0 {
		t.Fatalf("with no expected root, fsverity must not run: %+v", fsRunner.Invocations)
	}
}
