package etcsudoers

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
)

// IMP-01a0f109 (sudoers half): every grant field is concatenated into a
// root-owned sudoers drop-in. visudo -cf only proves the RESULT parses — an
// injected second rule is perfectly valid sudoers — and is skipped entirely
// when visudo is absent. So each field is checked before Render.

func baseGrant() manifest.ManifestSudoer {
	return manifest.ManifestSudoer{
		ID: "reload", User: "postgres", RunasUser: "root",
		Commands: []string{"/usr/bin/systemctl reload postgresql.service"},
	}
}

func TestApplyAtRefusesInjectedGrantFields(t *testing.T) {
	cases := map[string]func(g *manifest.ManifestSudoer){
		"command newline second rule": func(g *manifest.ManifestSudoer) {
			g.Commands = []string{"/bin/true\npnadmin ALL=(ALL) NOPASSWD: /bin/sh"}
		},
		"command carriage return": func(g *manifest.ManifestSudoer) { g.Commands = []string{"/bin/true\r/bin/sh"} },
		"command NUL":             func(g *manifest.ManifestSudoer) { g.Commands = []string{"/bin/true\x00"} },
		"command C1 NEL":          func(g *manifest.ManifestSudoer) { g.Commands = []string{"/bin/true\u0085x"} },
		"command invalid utf8":    func(g *manifest.ManifestSudoer) { g.Commands = []string{"/bin/true\xff"} },
		"command comma adds ALL":  func(g *manifest.ManifestSudoer) { g.Commands = []string{"/bin/true, ALL"} },
		"command bare ALL":        func(g *manifest.ManifestSudoer) { g.Commands = []string{"ALL"} },
		"command ALL argument":    func(g *manifest.ManifestSudoer) { g.Commands = []string{"/bin/true ALL"} },
		"command colon host spec": func(g *manifest.ManifestSudoer) { g.Commands = []string{"/bin/true : h = /bin/sh"} },
		"command equals":          func(g *manifest.ManifestSudoer) { g.Commands = []string{"/bin/x a=b"} },
		"command backslash":       func(g *manifest.ManifestSudoer) { g.Commands = []string{"/bin/x \\"} },
		"command relative":        func(g *manifest.ManifestSudoer) { g.Commands = []string{"bash"} },
		"no commands":             func(g *manifest.ManifestSudoer) { g.Commands = nil },
		"user newline":            func(g *manifest.ManifestSudoer) { g.User = "postgres\npnadmin" },
		"user list":               func(g *manifest.ManifestSudoer) { g.User = "postgres,pnadmin" },
		"user alias ALL":          func(g *manifest.ManifestSudoer) { g.User = "ALL" },
		"user group spec":         func(g *manifest.ManifestSudoer) { g.User = "%sudo" },
		"user reserved pnadmin":   func(g *manifest.ManifestSudoer) { g.User = "pnadmin" },
		"user reserved root":      func(g *manifest.ManifestSudoer) { g.User = "root" },
		"user empty":              func(g *manifest.ManifestSudoer) { g.User = "" },
		"runas paren escape": func(g *manifest.ManifestSudoer) {
			g.RunasUser = "root) NOPASSWD: ALL\n#"
		},
		"runas ALL":           func(g *manifest.ManifestSudoer) { g.RunasUser = "ALL" },
		"runas group newline": func(g *manifest.ManifestSudoer) { g.RunasGroup = "x\ny" },
		"flag injects rule":   func(g *manifest.ManifestSudoer) { g.Flags = []string{"SETENV: /bin/sh\npnadmin ALL=(ALL) NOPASSWD"} },
		"flag unknown tag":    func(g *manifest.ManifestSudoer) { g.Flags = []string{"PASSWD"} },
		"flag lowercase":      func(g *manifest.ManifestSudoer) { g.Flags = []string{"setenv"} },
	}
	prev := validateBody
	validateBody = func([]byte) error { return nil } // visudo absent: the field checks are the only gate
	defer func() { validateBody = prev }()

	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			bad := baseGrant()
			bad.ID = "bad"
			mutate(&bad)
			grants := []Grant{
				{ModuleName: "pg", Grant: bad},
				{ModuleName: "pg", Grant: baseGrant()},
			}
			err := ApplyAt(grants, dir, staticClock())
			if err == nil || !RefusalsOnly(err) {
				t.Fatalf("want a refusal-only error, got %v", err)
			}
			if _, statErr := os.Stat(filepath.Join(dir, "powernode-pg-bad")); !os.IsNotExist(statErr) {
				body, _ := os.ReadFile(filepath.Join(dir, "powernode-pg-bad"))
				t.Fatalf("injected grant written:\n%s", body)
			}
			if _, statErr := os.Stat(filepath.Join(dir, "powernode-pg-reload")); statErr != nil {
				t.Errorf("valid sibling grant not written: %v", statErr)
			}
			entries, _ := os.ReadDir(dir)
			for _, e := range entries {
				body, _ := os.ReadFile(filepath.Join(dir, e.Name()))
				if strings.Contains(string(body), "pnadmin") || strings.Count(string(body), "\n") != 2 {
					t.Errorf("%s carries an injected line:\n%s", e.Name(), body)
				}
			}
		})
	}
}

func TestCheckGrantAcceptsShippedShapes(t *testing.T) {
	ok := []manifest.ManifestSudoer{
		baseGrant(),
		{ID: "ops", User: "redis", RunasUser: "root", Commands: []string{"/bin/foo", "/bin/bar --flag value"}, Flags: []string{"SETENV", "NOPASSWD"}},
		{ID: "as", User: "svc-a", RunasUser: "svc-b", RunasGroup: "svc-b", Commands: []string{"/usr/bin/id"}},
		{ID: "dflt", User: "svc-a", Commands: []string{"/usr/bin/id"}},
	}
	for _, g := range ok {
		if err := CheckGrant(g); err != nil {
			t.Errorf("legit grant %q refused: %v", g.ID, err)
		}
	}
}
