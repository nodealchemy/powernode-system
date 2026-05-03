package identity

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestBootIdentityStrategy_Discover(t *testing.T) {
	tests := []struct {
		name           string
		identityCfg    string
		caFileContent  string
		caFileRelPath  string // relative to tmp dir; expanded to absolute in cfg
		wantErr        error
		assertIdentity func(*testing.T, *Identity)
	}{
		{
			name: "complete identity with KEY (Path A baked image)",
			identityCfg: `
ID=node-instance-uuid-123
KEY=bootstrap-token-abc
SERVER=https://platform.example.com
CA_PEM=-----BEGIN CERT-----\nABC\n-----END CERT-----
`,
			assertIdentity: func(t *testing.T, id *Identity) {
				if id.InstanceUUID != "node-instance-uuid-123" {
					t.Errorf("InstanceUUID = %q, want %q", id.InstanceUUID, "node-instance-uuid-123")
				}
				if id.BootstrapToken != "bootstrap-token-abc" {
					t.Errorf("BootstrapToken = %q, want %q", id.BootstrapToken, "bootstrap-token-abc")
				}
				if id.PlatformURL != "https://platform.example.com" {
					t.Errorf("PlatformURL = %q", id.PlatformURL)
				}
			},
		},
		{
			name: "Path C placeholder — empty ID + KEY, SERVER set",
			identityCfg: `
# pre-flash placeholder; agent will fill in token via claim flow
ID=
KEY=
SERVER=https://platform.example.com
`,
			assertIdentity: func(t *testing.T, id *Identity) {
				if id.InstanceUUID != "" {
					t.Errorf("InstanceUUID should be empty, got %q", id.InstanceUUID)
				}
				if id.BootstrapToken != "" {
					t.Errorf("BootstrapToken should be empty, got %q", id.BootstrapToken)
				}
				if id.PlatformURL != "https://platform.example.com" {
					t.Errorf("PlatformURL = %q", id.PlatformURL)
				}
			},
		},
		{
			name: "CA_PEM_FILE referenced + present",
			identityCfg: `
SERVER=https://example.com
CA_PEM_FILE={{CA_PATH}}
`,
			caFileContent: "-----BEGIN CERT-----\nFOO\n-----END CERT-----\n",
			caFileRelPath: "ca.pem",
			assertIdentity: func(t *testing.T, id *Identity) {
				want := "-----BEGIN CERT-----\nFOO\n-----END CERT-----\n"
				if id.CABundlePEM != want {
					t.Errorf("CABundlePEM = %q, want %q", id.CABundlePEM, want)
				}
			},
		},
		{
			name: "CA_PEM_FILE missing — silently empty",
			identityCfg: `
SERVER=https://example.com
CA_PEM_FILE=/does/not/exist.pem
`,
			assertIdentity: func(t *testing.T, id *Identity) {
				if id.CABundlePEM != "" {
					t.Errorf("CABundlePEM should be empty for missing file, got %q", id.CABundlePEM)
				}
			},
		},
		{
			name: "CA_PEM inline takes precedence over CA_PEM_FILE",
			identityCfg: `
SERVER=https://example.com
CA_PEM=inline-cert-content
CA_PEM_FILE=/does/not/exist.pem
`,
			assertIdentity: func(t *testing.T, id *Identity) {
				if id.CABundlePEM != "inline-cert-content" {
					t.Errorf("CABundlePEM = %q, want inline-cert-content", id.CABundlePEM)
				}
			},
		},
		{
			name:        "missing SERVER → ErrNotFound",
			identityCfg: "ID=foo\nKEY=bar\n",
			wantErr:     ErrNotFound,
		},
		{
			name: "comments + blank lines + quoted values handled",
			identityCfg: `
# leading comment
SERVER="https://quoted.example.com"
ID='quoted-id'
KEY=
`,
			assertIdentity: func(t *testing.T, id *Identity) {
				if id.PlatformURL != "https://quoted.example.com" {
					t.Errorf("PlatformURL = %q", id.PlatformURL)
				}
				if id.InstanceUUID != "quoted-id" {
					t.Errorf("InstanceUUID = %q", id.InstanceUUID)
				}
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			tmpDir := t.TempDir()
			cfgPath := filepath.Join(tmpDir, "identity.cfg")

			cfg := tt.identityCfg
			if tt.caFileRelPath != "" {
				caAbs := filepath.Join(tmpDir, tt.caFileRelPath)
				if err := os.WriteFile(caAbs, []byte(tt.caFileContent), 0o600); err != nil {
					t.Fatalf("write CA file: %v", err)
				}
				// Replace the placeholder in cfg with the absolute path.
				cfg = stringReplace(cfg, "{{CA_PATH}}", caAbs)
			}

			if err := os.WriteFile(cfgPath, []byte(cfg), 0o600); err != nil {
				t.Fatalf("write identity.cfg: %v", err)
			}

			s := &BootIdentityStrategy{Path: cfgPath}
			id, err := s.Discover(context.Background())

			if tt.wantErr != nil {
				if !errors.Is(err, tt.wantErr) {
					t.Errorf("err = %v, want %v", err, tt.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected err = %v", err)
			}
			if id == nil {
				t.Fatalf("identity is nil")
			}
			if tt.assertIdentity != nil {
				tt.assertIdentity(t, id)
			}
		})
	}
}

func TestBootIdentityStrategy_FileMissing(t *testing.T) {
	s := &BootIdentityStrategy{Path: "/path/that/does/not/exist.cfg"}
	_, err := s.Discover(context.Background())
	if !errors.Is(err, ErrNotFound) {
		t.Errorf("missing file: err = %v, want ErrNotFound", err)
	}
}

func TestBootIdentityStrategy_DefaultPath(t *testing.T) {
	// Path defaults to /boot/identity.cfg — almost certainly absent in
	// test environments. Just verify the default is used (returns
	// ErrNotFound on missing file rather than panicking on empty path).
	s := &BootIdentityStrategy{}
	if name := s.Name(); name != "boot-identity-cfg" {
		t.Errorf("Name() = %q", name)
	}
	_, err := s.Discover(context.Background())
	// Either ErrNotFound (file absent) or actual file present (don't
	// fail in either case — both prove default path resolved).
	if err != nil && !errors.Is(err, ErrNotFound) {
		t.Errorf("default path: unexpected err = %v", err)
	}
}

// stringReplace is a tiny helper to avoid pulling in strings just for
// one Replace call in tests. Keeps imports minimal.
func stringReplace(s, old, new string) string {
	out := []byte{}
	for i := 0; i < len(s); {
		if i+len(old) <= len(s) && s[i:i+len(old)] == old {
			out = append(out, new...)
			i += len(old)
		} else {
			out = append(out, s[i])
			i++
		}
	}
	return string(out)
}
