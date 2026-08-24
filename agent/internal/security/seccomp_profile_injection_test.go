package security

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// IMP-ce76b93d79fe — a module's config["security"]["seccomp_profile"] is
// author-controlled text that gets concatenated into a ROOT-OWNED systemd
// drop-in. Before the fix the only treatment it received was a strip of path
// components, so a newline in the value opened a second directive that
// systemd applies as root on every node carrying the module.
//
// Reproduction (pre-fix) — WriteSeccompDropIn produced, verbatim:
//
//	[Service]
//	SystemCallFilter=@deny
//	SystemCallFilter=
//	CapabilityBoundingSet=~
//	PrivateUsers=no
//	NoNewPrivileges=no
//	User=root
//	SystemCallErrorNumber=EPERM
//
// What that actually buys an attacker is a CONFINEMENT ESCAPE, not new root
// code execution — a module already controls its own units' ExecStart= via
// services[].start_command / unit_body (lifecycle/service.go). The escalation
// is drop-in precedence: systemd applies drop-ins in lexical filename order,
// and "seccomp.conf" sorts AFTER "ambient-capabilities.conf" and
// "capabilities.conf", so the injected CapabilityBoundingSet=~ /
// NoNewPrivileges=no / User=root override the bounding set the agent wrote to
// confine this module — something the module's own unit file cannot do.
// (The injected PrivateUsers=no does NOT stick: "userns.conf" sorts after
// "seccomp.conf" and wins. It is kept in the payload because the writer must
// refuse the whole string regardless of which lines would have taken effect.)
//
// SAFETY: these tests write ONLY into t.TempDir(). No systemctl, no real
// /etc/systemd/system, no node.
func TestWriteSeccompDropInRefusesInjection(t *testing.T) {
	injectionPayload := "/mods/evil/deny\n" +
		"SystemCallFilter=\n" +
		"CapabilityBoundingSet=~\n" +
		"PrivateUsers=no\n" +
		"NoNewPrivileges=no\n" +
		"User=root"

	cases := map[string]string{
		"the reproduction payload":     injectionPayload,
		"bare newline":                 "deny\nUser=root",
		"carriage return":              "deny\rUser=root",
		"NUL":                          "deny\x00User=root",
		"tab":                          "deny\tUser=root",
		"payload behind a path prefix": "/a\nExecStart=x/deny",
		"space (second token)":         "deny User=root",
		"systemd specifier":            "%h",
		"shell metacharacter":          "deny;id",
		"empty":                        "",
		"trailing slash, no base name": "/etc/seccomp/",
		"leading dot":                  ".hidden",
		"parent dir":                   "..",
		"over length":                  strings.Repeat("a", 65),
	}

	for name, payload := range cases {
		t.Run(name, func(t *testing.T) {
			root := withTempSystemdRoot(t)
			err := WriteSeccompDropIn("nginx.service", payload)
			if err == nil {
				body, _ := os.ReadFile(filepath.Join(root, "nginx.service.d", "seccomp.conf"))
				t.Fatalf("accepted %q — generated unit body:\n%s", payload, body)
			}
			// The refusal must be total: no drop-in file at all, so the
			// operator cannot mistake a partially-written unit for policy.
			if _, statErr := os.Stat(filepath.Join(root, "nginx.service.d", "seccomp.conf")); !os.IsNotExist(statErr) {
				t.Errorf("refused with %v but still wrote a drop-in", err)
			}
		})
	}
}

// A refusal that only lives in the writer would be near-silent: the
// reconciler treats drop-in write failures as non-fatal (OnError only), so
// the unit would start with NO seccomp confinement. Policy.Validate is the
// loud half — the reconciler refuses the whole module attach on any Validate
// error and reports it as a convergence failure.
func TestPolicyValidateRejectsInjectionProfile(t *testing.T) {
	p := &Policy{SeccompProfile: "deny\nUser=root", UserNamespace: true}
	errs := p.Validate()
	if len(errs) == 0 {
		t.Fatal("Validate accepted a newline-bearing seccomp_profile")
	}
	if !strings.Contains(errs[0].Error(), "control character") {
		t.Errorf("error should name the cause, got %v", errs[0])
	}
}

// OVER-REJECTION GUARD. Refusing a legitimate profile is its own defect —
// it would strand a module that is trying to confine itself. Every spelling
// a real manifest plausibly uses must still be accepted, and must still
// produce exactly the directive it produced before.
func TestSeccompFilterNameAcceptsLegitimateProfiles(t *testing.T) {
	// Post-contract (IMP-01a02f7d-fecd): security.seccomp_profile is a bare
	// systemd predefined syscall-set NAME resolving against the agent-owned
	// KnownSeccompSets. A '@' alias and a path prefix that reduces to a known
	// set name are still accepted (the '@'/path reduction can never turn an
	// invalid value valid); a profile FILE base name no longer is — see
	// TestSeccompFilterName_FailsClosedOnUnresolvableNames.
	cases := map[string]string{
		"system-service":               "system-service",
		"@system-service":              "system-service",
		"basic-io":                     "basic-io",
		"@network-io":                  "network-io",
		"/mnt/modules/abc123/basic-io": "basic-io",
		"default":                      "default",
		"sandbox":                      "sandbox",
	}
	for in, want := range cases {
		t.Run(in, func(t *testing.T) {
			got, err := SeccompFilterName(in)
			if err != nil {
				t.Fatalf("legitimate profile %q rejected: %v", in, err)
			}
			if got != want {
				t.Errorf("got %q want %q", got, want)
			}
		})
	}
}

func TestWriteSeccompDropInAcceptsLegitimateProfile(t *testing.T) {
	root := withTempSystemdRoot(t)
	if err := WriteSeccompDropIn("app.service", "/mnt/modules/abc123/profiles/system-service"); err != nil {
		t.Fatalf("legitimate profile rejected: %v", err)
	}
	got, err := os.ReadFile(filepath.Join(root, "app.service.d", "seccomp.conf"))
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	want := "[Service]\nSystemCallFilter=@system-service\nSystemCallErrorNumber=EPERM\n"
	if string(got) != want {
		t.Errorf("body mismatch:\ngot  %q\nwant %q", got, want)
	}
}

// A policy carrying a legitimate profile must still validate clean —
// Validate is on the attach path, so a false positive here bricks the module.
func TestPolicyValidateAcceptsLegitimateProfile(t *testing.T) {
	p := &Policy{SeccompProfile: "profiles/system-service", UserNamespace: true}
	if errs := p.Validate(); len(errs) != 0 {
		t.Fatalf("legitimate policy rejected: %v", errs)
	}
}
