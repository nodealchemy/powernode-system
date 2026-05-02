package identity

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestParseCmdline(t *testing.T) {
	got := parseCmdline(`BOOT_IMAGE=/vmlinuz powernode.instance_uuid=abc-123 powernode.platform_url="https://p.example.com/foo bar" simple_flag`)
	want := map[string]string{
		"BOOT_IMAGE":               "/vmlinuz",
		"powernode.instance_uuid":  "abc-123",
		"powernode.platform_url":   "https://p.example.com/foo bar",
		"simple_flag":              "",
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("key %q: got %q, want %q", k, got[k], v)
		}
	}
}

func TestCmdlineStrategy(t *testing.T) {
	dir := t.TempDir()
	cmdline := filepath.Join(dir, "cmdline")
	body := `console=ttyS0 powernode.instance_uuid=test-uuid-1 powernode.bootstrap_token=tok-xyz powernode.platform_url=https://p.example.com`
	if err := os.WriteFile(cmdline, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}

	s := &CmdlineStrategy{Path: cmdline}
	id, err := s.Discover(context.Background())
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}
	if id.InstanceUUID != "test-uuid-1" {
		t.Errorf("InstanceUUID = %q", id.InstanceUUID)
	}
	if id.BootstrapToken != "tok-xyz" {
		t.Errorf("BootstrapToken = %q", id.BootstrapToken)
	}
	if id.PlatformURL != "https://p.example.com" {
		t.Errorf("PlatformURL = %q", id.PlatformURL)
	}
}

func TestCmdlineStrategy_Missing(t *testing.T) {
	s := &CmdlineStrategy{Path: "/nonexistent/path"}
	_, err := s.Discover(context.Background())
	if !errors.Is(err, ErrNotFound) {
		t.Errorf("expected ErrNotFound, got %v", err)
	}
}

func TestFwCfgStrategy(t *testing.T) {
	dir := t.TempDir()
	for _, kv := range [][]string{
		{"instance_uuid", "fw-uuid-99"},
		{"bootstrap_token", "fw-tok"},
		{"platform_url", "https://p.fw.example.com"},
	} {
		key, val := kv[0], kv[1]
		sub := filepath.Join(dir, key)
		if err := os.MkdirAll(sub, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(sub, "raw"), []byte(val+"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	s := &FwCfgStrategy{Root: dir}
	id, err := s.Discover(context.Background())
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}
	if id.InstanceUUID != "fw-uuid-99" {
		t.Errorf("InstanceUUID = %q", id.InstanceUUID)
	}
	if id.PlatformURL != "https://p.fw.example.com" {
		t.Errorf("PlatformURL = %q", id.PlatformURL)
	}
	if id.CloudProvider != "libvirt-fw-cfg" {
		t.Errorf("CloudProvider = %q", id.CloudProvider)
	}
}

func TestLocalIdentityStrategy(t *testing.T) {
	dir := t.TempDir()
	cfg := filepath.Join(dir, "identity.cfg")
	body := `# legacy identity format
ID="local-uuid-7"
export KEY=local-token
SERVER='https://p.local.example.com'
`
	if err := os.WriteFile(cfg, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	s := &LocalIdentityStrategy{Path: cfg}
	id, err := s.Discover(context.Background())
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}
	if id.InstanceUUID != "local-uuid-7" {
		t.Errorf("InstanceUUID = %q", id.InstanceUUID)
	}
	if id.BootstrapToken != "local-token" {
		t.Errorf("BootstrapToken = %q", id.BootstrapToken)
	}
	if id.PlatformURL != "https://p.local.example.com" {
		t.Errorf("PlatformURL = %q", id.PlatformURL)
	}
}

func TestResolver_PicksFirstHit(t *testing.T) {
	fs1 := &fakeStrategyImpl{name: "first", err: ErrNotFound}
	fs2 := &fakeStrategyImpl{name: "second", id: &Identity{InstanceUUID: "second-hit"}}
	fs3 := &fakeStrategyImpl{name: "third", id: &Identity{InstanceUUID: "third-hit"}}

	r := &Resolver{Strategies: []Strategy{fs1, fs2, fs3}}
	id, err := r.Resolve(context.Background())
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if id.InstanceUUID != "second-hit" {
		t.Errorf("expected second-hit, got %q", id.InstanceUUID)
	}
	if id.Architecture == "" {
		t.Errorf("Architecture should be filled from runtime.GOARCH")
	}
}

func TestResolver_AllNotFound(t *testing.T) {
	r := &Resolver{Strategies: []Strategy{
		&fakeStrategyImpl{name: "a", err: ErrNotFound},
		&fakeStrategyImpl{name: "b", err: ErrNotFound},
	}}
	_, err := r.Resolve(context.Background())
	if !errors.Is(err, ErrNotFound) {
		t.Errorf("expected ErrNotFound, got %v", err)
	}
}

// fakeStrategyImpl is a minimal Strategy for table-style tests.
type fakeStrategyImpl struct {
	name string
	id   *Identity
	err  error
}

func (f *fakeStrategyImpl) Name() string { return f.name }
func (f *fakeStrategyImpl) Discover(_ context.Context) (*Identity, error) {
	return f.id, f.err
}
