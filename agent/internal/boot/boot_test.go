package boot

import (
	"context"
	"errors"
	"io/fs"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/enroll"
	"github.com/nodealchemy/powernode-system/agent/internal/identity"
)

// enrollClientReal is just enroll.Client — alias makes the
// enrollClientStub indirection compile cleanly.
type enrollClientReal = enroll.Client

// stubResolverStrategy returns a canned Identity (or error) every
// time Discover is called.
type stubResolverStrategy struct {
	id  *identity.Identity
	err error
}

func (s *stubResolverStrategy) Name() string { return "stub" }
func (s *stubResolverStrategy) Discover(_ context.Context) (*identity.Identity, error) {
	if s.err != nil {
		return nil, s.err
	}
	return s.id, nil
}

func makeResolver(id *identity.Identity) *identity.Resolver {
	return &identity.Resolver{
		Strategies: []identity.Strategy{&stubResolverStrategy{id: id}},
		Timeout:    100 * time.Millisecond,
	}
}

// fakeStat lets tests pretend specific files exist.
type fakeStat struct {
	files map[string]int64
}

func (f *fakeStat) stat(p string) (fs.FileInfo, error) {
	if size, ok := f.files[p]; ok {
		return &fakeFI{size: size}, nil
	}
	return nil, errors.New("not found")
}

type fakeFI struct{ size int64 }

func (f *fakeFI) Name() string       { return "" }
func (f *fakeFI) Size() int64        { return f.size }
func (f *fakeFI) Mode() fs.FileMode  { return 0o644 }
func (f *fakeFI) ModTime() time.Time { return time.Time{} }
func (f *fakeFI) IsDir() bool        { return false }
func (f *fakeFI) Sys() any           { return nil }

func TestBootDryRunSkipsSwitchRoot(t *testing.T) {
	id := &identity.Identity{
		InstanceUUID:   "instance-1",
		BootstrapToken: "tok",
		PlatformURL:    "https://platform",
		CABundlePEM:    "fake-ca",
	}
	swap := false
	o := Orchestrator{
		Resolver:     makeResolver(id),
		EnrollClient: enrollNeverCalled(t),
		DryRun:       true,
		SwitchRoot: func(_ string) error {
			swap = true
			return nil
		},
	}.Default()

	if err := o.Boot(context.Background()); err != nil {
		t.Fatalf("Boot: %v", err)
	}
	if swap {
		t.Errorf("dry-run should NOT call SwitchRoot")
	}
}

func TestBootRequiresResolver(t *testing.T) {
	o := &Orchestrator{}
	err := o.Boot(context.Background())
	if err == nil || !strings.Contains(err.Error(), "Resolver required") {
		t.Errorf("expected Resolver-required error, got %v", err)
	}
}

func TestBootRequiresEnrollClient(t *testing.T) {
	o := &Orchestrator{Resolver: makeResolver(&identity.Identity{InstanceUUID: "x"})}
	err := o.Boot(context.Background())
	if err == nil || !strings.Contains(err.Error(), "EnrollClient required") {
		t.Errorf("expected EnrollClient-required error, got %v", err)
	}
}

func TestBootSurfacesIdentityError(t *testing.T) {
	r := &identity.Resolver{
		Strategies: []identity.Strategy{
			&stubResolverStrategy{err: errors.New("boom")},
		},
	}
	o := Orchestrator{
		Resolver:     r,
		EnrollClient: enrollNeverCalled(t),
	}.Default()

	err := o.Boot(context.Background())
	if err == nil {
		t.Errorf("expected error from resolver")
	}
}

func TestBootRecordsStages(t *testing.T) {
	id := &identity.Identity{
		InstanceUUID:   "i1",
		BootstrapToken: "tok",
		PlatformURL:    "https://platform",
		CABundlePEM:    "fake",
	}
	var mu sync.Mutex
	stages := []string{}
	o := Orchestrator{
		Resolver:     makeResolver(id),
		EnrollClient: enrollNeverCalled(t),
		DryRun:       true,
		OnStage: func(stage, _ string) {
			mu.Lock()
			defer mu.Unlock()
			stages = append(stages, stage)
		},
	}.Default()

	o.Boot(context.Background())

	mu.Lock()
	defer mu.Unlock()
	// dry-run emits: identity-start, identity-ok, enroll-skip, mount-start,
	// mount-plan, mount-ok, switch_root-skip. Each call appends the stage name.
	want := []string{"identity", "identity", "enroll", "mount", "mount", "mount", "switch_root"}
	if len(stages) != len(want) {
		t.Fatalf("stages: got %v want %v", stages, want)
	}
	for i := range want {
		if stages[i] != want[i] {
			t.Errorf("stages[%d]: got %q want %q", i, stages[i], want[i])
		}
	}
}

func TestHasUsableCertChecksAllFiles(t *testing.T) {
	original := osStat
	defer func() { osStat = original }()

	files := &fakeStat{files: map[string]int64{}}
	osStat = files.stat

	paths := pathsForTest("/persist/var/lib/powernode/pki")
	if hasUsableCert(paths, "https://x") {
		t.Errorf("expected false when no files exist")
	}

	files.files[paths.Cert] = 100
	files.files[paths.Key] = 100
	if hasUsableCert(paths, "https://x") {
		t.Errorf("expected false when CABundle missing")
	}

	files.files[paths.CABundle] = 100
	if !hasUsableCert(paths, "https://x") {
		t.Errorf("expected true when all 3 files present")
	}
}

func TestFileNonEmptyZeroSizeFails(t *testing.T) {
	original := osStat
	defer func() { osStat = original }()
	osStat = func(_ string) (fs.FileInfo, error) {
		return &fakeFI{size: 0}, nil
	}
	if fileNonEmpty("/anything") {
		t.Errorf("zero-size file should not be considered usable")
	}
}

// enrollNeverCalled returns an enroll.Client constructed but never
// invoked — tests set DryRun=true so the orchestrator skips the
// enroll path entirely. The client is non-nil so the Boot guard
// for "EnrollClient required" passes.
func enrollNeverCalled(t *testing.T) *enrollClientStub {
	t.Helper()
	return &enrollClientStub{}
}

// enrollClientStub satisfies the *enroll.Client field shape via Go's
// structural assignment (we use the real type in the agent; the
// stub's only purpose is to give Boot a non-nil receiver for its
// guard check). Tests with DryRun=false would need a real
// httptest-backed client; those land alongside the integration
// smoke test.
type enrollClientStub = enrollClientReal

// pathsForTest delegates to enroll.PathsUnder so the test stays in
// sync with the canonical PKI layout.
func pathsForTest(dir string) enroll.PKIPaths {
	return enroll.PathsUnder(dir)
}
