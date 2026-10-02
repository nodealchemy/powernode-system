package security

import (
	"context"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/writeguard"
)

// IMP-d869a06dfc57 — the security package's host-global writers default to the
// real /etc/systemd/system and /run/powernode-agent, and its profile loaders
// and nft calls act on the real host through mount.ExecRunner. Each override
// seam is opt-in; one a test forgets is silent until the suite runs as root.

const guardProbeUnit = "powernode-00000000-guard-probe.service"

// Every default-target entry point is refused by the guard BEFORE any I/O: the
// verdict is on the resolved path, so these are safe run unprivileged, and the
// sandboxed arm of each is covered by the package's own tests.
func TestDefaultTargetsAreRefusedUnderTheGuard(t *testing.T) {
	calls := map[string]func() error{
		"WriteCapabilityDropIn":  func() error { _, err := WriteCapabilityDropIn(guardProbeUnit, []string{"CAP_CHOWN"}); return err },
		"RemoveCapabilityDropIn": func() error { _, err := RemoveCapabilityDropIn(guardProbeUnit); return err },
		"RemoveLegacyAmbientCapabilityDropIn": func() error {
			_, err := RemoveLegacyAmbientCapabilityDropIn(guardProbeUnit)
			return err
		},
		"WriteSeccompDropIn":  func() error { _, err := WriteSeccompDropIn(guardProbeUnit, "/etc/seccomp/system-service"); return err },
		"RemoveSeccompDropIn": func() error { _, err := RemoveSeccompDropIn(guardProbeUnit); return err },
		"WriteUserNamespaceDropIn": func() error {
			_, err := WriteUserNamespaceDropIn(guardProbeUnit, true)
			return err
		},
		"WriteRawDropInFileForRestore": func() error {
			return WriteRawDropInFileForRestore("/etc/systemd/system/"+guardProbeUnit+".d", "zz-guard-probe.conf", "[Service]\n")
		},
		// A root of "/" is the real host: the *At variants are only as safe as the root they are given.
		"WriteCapabilityDropInAt(/)": func() error { _, err := WriteCapabilityDropInAt("/", guardProbeUnit, nil); return err },
		"ApplyEgressAllowlist (default script path)": func() error {
			return ApplyEgressAllowlist(context.Background(), &mount.RecorderRunner{}, nil)
		},
	}
	for name, call := range calls {
		var err error
		rec := writeguard.Capture(func() { err = call() })
		if err == nil || len(rec) != 1 {
			t.Errorf("%s: default/out-of-sandbox target was not refused (err=%v, recorded=%d)", name, err, len(rec))
		}
	}
}

// The sandboxed arm: the same writers, given a root under the temp dir, are not refused.
func TestSandboxedDropInWritesAreNotRefused(t *testing.T) {
	root := t.TempDir()
	var err error
	rec := writeguard.Capture(func() { _, err = WriteCapabilityDropInAt(root, guardProbeUnit, []string{"CAP_CHOWN"}) })
	if err != nil || len(rec) != 0 {
		t.Fatalf("a sandboxed write was refused (err=%v, recorded=%v)", err, rec)
	}
	if _, statErr := os.Stat(filepath.Join(root, "etc", "systemd", "system", guardProbeUnit+".d", "capabilities.conf")); statErr != nil {
		t.Fatalf("the sandboxed write did not land: %v", statErr)
	}
}

// A real command runner is a host-global effect with no path to inspect: the
// production runner is refused under the guard, a recorder passes through.
func TestRealRunnerIsRefusedUnderTheGuardAndARecorderIsNot(t *testing.T) {
	var err error
	rec := writeguard.Capture(func() { err = runHost(context.Background(), mount.ExecRunner{}, "true") })
	if err == nil || len(rec) != 1 {
		t.Errorf("the production runner was not refused (err=%v, recorded=%d)", err, len(rec))
	}
	rec = writeguard.Capture(func() { err = runHost(context.Background(), &mount.ExecRunner{}, "true") })
	if err == nil || len(rec) != 1 {
		t.Errorf("a pointer to the production runner was not refused (err=%v, recorded=%d)", err, len(rec))
	}

	recorder := &mount.RecorderRunner{}
	rec = writeguard.Capture(func() { err = runHost(context.Background(), recorder, "nft", "-f", "x") })
	if err != nil || len(rec) != 0 {
		t.Errorf("a recorder runner was refused (err=%v, recorded=%v)", err, rec)
	}
	if len(recorder.Invocations) != 1 {
		t.Errorf("the recorder did not receive the call: %v", recorder.Invocations)
	}
}

// The ratchet: a command run through a Runner anywhere in this package's
// non-test code must go through runHost, or a new call site would silently
// bypass the guard. Parsed, not grepped: any selector named like a Runner
// method (call or method value, any receiver name, any spacing) is flagged
// outside host_guard.go, the one file that may touch the runner.
func TestEveryRunnerCallGoesThroughRunHost(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	runnerMethods := map[string]bool{"Run": true, "Output": true, "RunStdin": true, "OutputBounded": true}
	fset := token.NewFileSet()
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") || f == "host_guard.go" {
			continue
		}
		parsed, err := parser.ParseFile(fset, f, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		ast.Inspect(parsed, func(n ast.Node) bool {
			if sel, ok := n.(*ast.SelectorExpr); ok && runnerMethods[sel.Sel.Name] {
				t.Errorf("%s: %s uses a Runner method directly; use runHost", fset.Position(sel.Pos()), sel.Sel.Name)
			}
			return true
		})
	}
}

// A test double that wraps the production runner is still the production runner.
type wrappingRunner struct{ mount.Runner }

func TestWrappedProductionRunnerIsRefused(t *testing.T) {
	var err error
	rec := writeguard.Capture(func() {
		err = runHost(context.Background(), &wrappingRunner{Runner: mount.ExecRunner{}}, "true")
	})
	if err == nil || len(rec) != 1 {
		t.Errorf("a wrapped production runner was not refused (err=%v, recorded=%d)", err, len(rec))
	}
	recorder := &mount.RecorderRunner{}
	rec = writeguard.Capture(func() {
		err = runHost(context.Background(), &wrappingRunner{Runner: recorder}, "nft")
	})
	if err != nil || len(rec) != 0 {
		t.Errorf("a wrapped recorder was refused (err=%v, recorded=%v)", err, rec)
	}
}

// A filename that climbs out of the drop-in directory is judged by where it lands.
func TestDropInFilenameThatClimbsOutIsRefused(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "unit.d")
	var err error
	rec := writeguard.Capture(func() {
		_, err = writeDropInFile(dir, "../../../../../../../../etc/zz-guard-probe.conf", "[Service]\n")
	})
	if err == nil || len(rec) != 1 {
		t.Errorf("a climbing filename was not refused (err=%v, recorded=%d)", err, len(rec))
	}
}
