package security

import (
	"strings"
	"testing"
)

// G2 offer 01a02f7d-fecd — the SECURITY-BLOCK CONTRACT resolves the
// path-vs-set-name ambiguity: seccomp_profile is a bare NAME resolved
// against an agent-owned profile set, failing CLOSED. The agent-owned set
// is the compiled-in list of systemd predefined syscall sets — the only
// names that yield a SystemCallFilter=@<name> directive systemd actually
// honours. A file base name or path spelling can no longer launder itself
// into an inert directive.
func TestSeccompFilterName_FailsClosedOnUnresolvableNames(t *testing.T) {
	cases := []string{
		"deny.json",                            // file base name — inert directive pre-fix
		"profiles/deny.json",                   // module-relative path
		"./profiles/deny.json",                 // module-relative path
		"/mnt/modules/abc123/seccomp/app.json", // absolute path
		"not-a-real-set",                       // grammar-valid but resolves nowhere
		"default_deny",                         // underscore — no systemd set uses one
	}
	for _, in := range cases {
		t.Run(in, func(t *testing.T) {
			name, err := SeccompFilterName(in)
			if err == nil {
				t.Fatalf("accepted %q -> %q; a name that does not resolve against the agent-owned set must fail closed", in, name)
			}
		})
	}
}

// Resolution guard: every systemd predefined syscall set a manifest
// plausibly declares still resolves, with and without the '@' alias.
func TestSeccompFilterName_ResolvesSystemdSets(t *testing.T) {
	cases := map[string]string{
		"system-service":  "system-service",
		"@system-service": "system-service",
		"basic-io":        "basic-io",
		"@network-io":     "network-io",
		"default":         "default",
		"sandbox":         "sandbox",
	}
	for in, want := range cases {
		got, err := SeccompFilterName(in)
		if err != nil {
			t.Errorf("SeccompFilterName(%q): %v", in, err)
			continue
		}
		if got != want {
			t.Errorf("SeccompFilterName(%q) = %q, want %q", in, got, want)
		}
	}
	// The resolution failure must say so, so an operator can tell
	// "unknown set" from "hostile characters".
	if _, err := SeccompFilterName("no-such-set"); err == nil || !strings.Contains(err.Error(), "resolve") {
		t.Errorf("unresolvable-name error should mention resolution; got %v", err)
	}
}
