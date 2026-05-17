package federation

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// stageFwCfg writes a key/raw fixture under root so LoadConfig can
// read it. Returns the path written for convenience.
func stageFwCfg(t *testing.T, root, key, value string) string {
	t.Helper()
	dir := filepath.Join(root, key)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", dir, err)
	}
	path := filepath.Join(dir, "raw")
	if err := os.WriteFile(path, []byte(value), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
	return path
}

func TestLoadConfig_NotConfigured_WhenNoParentURL(t *testing.T) {
	root := t.TempDir()
	cfg, err := LoadConfig(root)
	if !errors.Is(err, ErrNotConfigured) {
		t.Fatalf("expected ErrNotConfigured, got cfg=%+v err=%v", cfg, err)
	}
	if cfg != nil {
		t.Fatalf("expected nil config, got %+v", cfg)
	}
}

func TestLoadConfig_HappyPath(t *testing.T) {
	root := t.TempDir()
	stageFwCfg(t, root, "parent_url", "https://parent.example.com")
	stageFwCfg(t, root, "acceptance_token", "tok-xyz-123")
	stageFwCfg(t, root, "spawn_mode", "managed_child")
	stageFwCfg(t, root, "parent_peer_id", "019e3240-aaaa-7fff-bccc-dddddddddddd")
	stageFwCfg(t, root, "contract_version", "v1")

	cfg, err := LoadConfig(root)
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if cfg.ParentURL != "https://parent.example.com" {
		t.Errorf("parent_url: got %q", cfg.ParentURL)
	}
	if cfg.AcceptanceToken != "tok-xyz-123" {
		t.Errorf("acceptance_token: got %q", cfg.AcceptanceToken)
	}
	if cfg.SpawnMode != "managed_child" {
		t.Errorf("spawn_mode: got %q", cfg.SpawnMode)
	}
	if cfg.ContractVersion != "v1" {
		t.Errorf("contract_version: got %q", cfg.ContractVersion)
	}
}

func TestLoadConfig_DefaultsContractVersion(t *testing.T) {
	root := t.TempDir()
	stageFwCfg(t, root, "parent_url", "https://parent.example.com")
	stageFwCfg(t, root, "acceptance_token", "tok-xyz-123")
	// No contract_version key — should default to v1

	cfg, err := LoadConfig(root)
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if cfg.ContractVersion != "v1" {
		t.Errorf("expected default v1, got %q", cfg.ContractVersion)
	}
}

func TestLoadConfig_RequiresTokenWhenURLPresent(t *testing.T) {
	root := t.TempDir()
	stageFwCfg(t, root, "parent_url", "https://parent.example.com")
	// No acceptance_token — should error

	_, err := LoadConfig(root)
	if err == nil {
		t.Fatalf("expected error for missing token")
	}
	if err == ErrNotConfigured {
		t.Fatalf("missing-token error should not be ErrNotConfigured (this is a partial seed, not absent seed)")
	}
}

func TestLoadConfig_TrimsWhitespace(t *testing.T) {
	root := t.TempDir()
	stageFwCfg(t, root, "parent_url", "  https://parent.example.com  \n")
	stageFwCfg(t, root, "acceptance_token", "\ttok-xyz-123\n")

	cfg, err := LoadConfig(root)
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if cfg.ParentURL != "https://parent.example.com" {
		t.Errorf("parent_url not trimmed: %q", cfg.ParentURL)
	}
	if cfg.AcceptanceToken != "tok-xyz-123" {
		t.Errorf("acceptance_token not trimmed: %q", cfg.AcceptanceToken)
	}
}
