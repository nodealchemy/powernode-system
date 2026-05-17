package tcpfwd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestConfigValidate_AcceptsCompleteForward(t *testing.T) {
	cfg := &Config{
		Forwards: []Forward{
			{Listen: "127.0.0.1:5432", Backend: "[fd00::1]:5432", Protocol: "tcp",
				SubscriptionID: "abc-123"},
		},
	}
	if err := cfg.Validate(); err != nil {
		t.Fatalf("expected valid config, got error: %v", err)
	}
}

func TestConfigValidate_RejectsEmptyListen(t *testing.T) {
	cfg := &Config{
		Forwards: []Forward{{Listen: "", Backend: "[::1]:5432", Protocol: "tcp"}},
	}
	err := cfg.Validate()
	if err == nil || !strings.Contains(err.Error(), "listen") {
		t.Fatalf("expected listen-error, got %v", err)
	}
}

func TestConfigValidate_RejectsEmptyBackend(t *testing.T) {
	cfg := &Config{
		Forwards: []Forward{{Listen: "127.0.0.1:5432", Backend: "", Protocol: "tcp"}},
	}
	err := cfg.Validate()
	if err == nil || !strings.Contains(err.Error(), "backend") {
		t.Fatalf("expected backend-error, got %v", err)
	}
}

func TestConfigValidate_RejectsNonTcpProtocol(t *testing.T) {
	cfg := &Config{
		Forwards: []Forward{{Listen: "127.0.0.1:5432", Backend: "[::1]:5432", Protocol: "udp"}},
	}
	err := cfg.Validate()
	if err == nil || !strings.Contains(err.Error(), "tcp") {
		t.Fatalf("expected protocol-error, got %v", err)
	}
}

func TestConfigValidate_FlagsTheFirstBadIndex(t *testing.T) {
	cfg := &Config{
		Forwards: []Forward{
			{Listen: "127.0.0.1:5432", Backend: "[::1]:5432", Protocol: "tcp"},
			{Listen: "", Backend: "[::1]:6379", Protocol: "tcp"},
		},
	}
	err := cfg.Validate()
	if err == nil || !strings.Contains(err.Error(), "forwards[1]") {
		t.Fatalf("expected forwards[1] error, got %v", err)
	}
}

func TestLoadConfig_ReadsValidJSON(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "tcpfwd.json")
	contents := `{
	  "forwards": [
	    {"listen": "127.0.0.1:5432", "backend": "[fd00::1]:5432", "protocol": "tcp", "subscription_id": "abc"}
	  ]
	}`
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := LoadConfig(path)
	if err != nil {
		t.Fatalf("expected success, got: %v", err)
	}
	if len(cfg.Forwards) != 1 || cfg.Forwards[0].Listen != "127.0.0.1:5432" {
		t.Fatalf("unexpected parse result: %+v", cfg)
	}
}

func TestLoadConfig_ErrorsOnMissingFile(t *testing.T) {
	_, err := LoadConfig("/nonexistent/path/tcpfwd.json")
	if err == nil || !strings.Contains(err.Error(), "read config") {
		t.Fatalf("expected read-error, got: %v", err)
	}
}

func TestLoadConfig_ErrorsOnMalformedJSON(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "bad.json")
	if err := os.WriteFile(path, []byte("not json at all"), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err := LoadConfig(path)
	if err == nil || !strings.Contains(err.Error(), "parse config") {
		t.Fatalf("expected parse-error, got: %v", err)
	}
}

func TestLoadConfig_ErrorsOnSemanticInvalid(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "invalid.json")
	contents := `{"forwards": [{"listen": "", "backend": "[::1]:5432", "protocol": "tcp"}]}`
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err := LoadConfig(path)
	if err == nil || !strings.Contains(err.Error(), "invalid config") {
		t.Fatalf("expected invalid-config error, got: %v", err)
	}
}
