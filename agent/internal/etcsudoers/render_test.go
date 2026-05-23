package etcsudoers

import (
	"strings"
	"testing"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
)

func TestRenderBasicGrant(t *testing.T) {
	g := Grant{
		ModuleName: "powernode-postgres",
		Grant: manifest.ManifestSudoer{
			ID:        "reload",
			User:      "postgres",
			RunasUser: "root",
			Commands:  []string{"/usr/bin/systemctl reload postgresql.service"},
		},
	}
	body := string(Render(g, time.Date(2026, 5, 22, 12, 0, 0, 0, time.UTC)))

	wants := []string{
		"# Managed by Powernode: module=powernode-postgres, grant_id=reload",
		"postgres ALL=(root) NOPASSWD: /usr/bin/systemctl reload postgresql.service\n",
	}
	for _, want := range wants {
		if !strings.Contains(body, want) {
			t.Errorf("Render output missing %q\nfull output:\n%s", want, body)
		}
	}
}

func TestRenderHandlesMultipleCommandsAndFlags(t *testing.T) {
	g := Grant{
		ModuleName: "powernode-redis",
		Grant: manifest.ManifestSudoer{
			ID:        "ops",
			User:      "redis",
			RunasUser: "root",
			Commands:  []string{"/bin/foo", "/bin/bar"},
			Flags:     []string{"SETENV"},
		},
	}
	body := string(Render(g, time.Date(2026, 5, 22, 0, 0, 0, 0, time.UTC)))
	want := "redis ALL=(root) NOPASSWD,SETENV: /bin/foo, /bin/bar\n"
	if !strings.Contains(body, want) {
		t.Errorf("expected %q\nfull output:\n%s", want, body)
	}
}

func TestRenderDefaultsRunasToRoot(t *testing.T) {
	g := Grant{
		ModuleName: "x",
		Grant:      manifest.ManifestSudoer{ID: "y", User: "u", Commands: []string{"/bin/ls"}},
	}
	body := string(Render(g, time.Now()))
	if !strings.Contains(body, "ALL=(root)") {
		t.Errorf("expected default runas=root, got:\n%s", body)
	}
}

func TestRenderHonorsRunasGroup(t *testing.T) {
	g := Grant{
		ModuleName: "x",
		Grant: manifest.ManifestSudoer{
			ID: "y", User: "u", RunasUser: "alice", RunasGroup: "bob",
			Commands: []string{"/bin/ls"},
		},
	}
	body := string(Render(g, time.Now()))
	if !strings.Contains(body, "ALL=(alice:bob)") {
		t.Errorf("expected runas=alice:bob, got:\n%s", body)
	}
}

func TestFilenameFormat(t *testing.T) {
	g := Grant{
		ModuleName: "powernode-postgres",
		Grant:      manifest.ManifestSudoer{ID: "reload"},
	}
	want := "powernode-powernode-postgres-reload"
	if g.Filename() != want {
		t.Errorf("Filename = %q want %q", g.Filename(), want)
	}
}
