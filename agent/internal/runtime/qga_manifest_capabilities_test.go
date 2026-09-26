package runtime

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/security"
	"gopkg.in/yaml.v3"
)

// THE REAL MANIFEST, not a fixture reproducing it (review round, IMP-caef5c00d63f
// phase 3 — "no test reads the real qga manifest"). Every other test in this
// package pins the RESOLVER against hand-written fixtures; this one pins the
// on-disk source of truth (modules/qemu-guest-agent/manifest.yaml) against
// that resolver, so an edit to the manifest that quietly narrows or widens
// qga's ceiling — the host-root recovery channel this control plane cannot
// otherwise repair itself through — fails a test instead of only surfacing on
// a live node.
//
// loadModuleManifestYAML bridges the on-disk AUTHORING schema (YAML,
// `security:` at the top level) to the agent's wire-format manifest.Manifest
// (JSON-shaped, `security` nested under Config) — the same reshaping the
// server's own ManifestImportService performs when it serializes a module for
// the node API. Only the fields this test needs are carried across.
func loadModuleManifestYAML(t *testing.T, moduleDir string) *manifest.Manifest {
	t.Helper()
	path := filepath.Join("..", "..", "..", "modules", moduleDir, "manifest.yaml")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v (run from agent/internal/runtime? cwd assumption may be stale)", path, err)
	}
	var doc struct {
		Name     string `yaml:"name"`
		Security struct {
			// *[]string, not []string (review F5): a YAML sequence node
			// (including an EXPLICIT `capabilities: []`) always decodes to a
			// non-nil pointer here, while an ABSENT key leaves the pointer
			// nil — the same presence-vs-emptiness distinction
			// manifest.ServiceCapabilities carries for the per-service key,
			// now carried for the module-level ceiling too, so this reader
			// matches what the server's own serializer would emit for either
			// shape rather than collapsing both to "omit the key".
			Capabilities  *[]string `yaml:"capabilities"`
			UserNamespace *bool     `yaml:"user_namespace"`
			Privileged    bool      `yaml:"privileged"`
			// SeccompProfile (review F5): "pin qga cannot be refused" needs
			// to assert qga declares NONE, which requires this reader to
			// actually carry the field through — seccomp has no full-set-
			// style exemption (compose.go / security_dropins.go), so a
			// manifest that ever adds one to qga reintroduces exactly the
			// fail-closed risk the capability/userns exemptions exist to
			// keep qga out of.
			SeccompProfile string `yaml:"seccomp_profile"`
		} `yaml:"security"`
		Services []struct {
			Name         string   `yaml:"name"`
			Capabilities []string `yaml:"capabilities"`
		} `yaml:"services"`
	}
	if err := yaml.Unmarshal(raw, &doc); err != nil {
		t.Fatalf("parse %s: %v", path, err)
	}

	secCfg := map[string]any{
		"privileged": doc.Security.Privileged,
	}
	if doc.Security.Capabilities != nil {
		caps := make([]any, len(*doc.Security.Capabilities))
		for i, c := range *doc.Security.Capabilities {
			caps[i] = c
		}
		secCfg["capabilities"] = caps
	}
	if doc.Security.UserNamespace != nil {
		secCfg["user_namespace"] = *doc.Security.UserNamespace
	}
	if doc.Security.SeccompProfile != "" {
		secCfg["seccomp_profile"] = doc.Security.SeccompProfile
	}

	services := make([]manifest.Service, 0, len(doc.Services))
	for _, s := range doc.Services {
		svc := manifest.Service{Name: s.Name, StartCommand: "/bin/true"}
		// A service-level `capabilities:` key in the YAML is a DECLARATION
		// (including an empty list) — mirrored here through the JSON
		// UnmarshalJSON path so ServiceCapabilities.Declared is set exactly
		// as it would be from the real wire payload. Absence (nil in the
		// decoded YAML) leaves Declared=false — inherit the ceiling.
		if s.Capabilities != nil {
			svc.Capabilities = declaredCaps(t, s.Capabilities)
		}
		services = append(services, svc)
	}

	return &manifest.Manifest{
		ID:                          doc.Name,
		Name:                        doc.Name,
		ServiceCapabilitiesPresence: true,
		Config:                      map[string]any{"security": secCfg},
		Services:                    services,
	}
}

func declaredCaps(t *testing.T, names []string) manifest.ServiceCapabilities {
	t.Helper()
	// ServiceCapabilities.UnmarshalJSON is the one place that sets Declared
	// from key PRESENCE — round-trip through it rather than constructing the
	// struct by hand, so this test exercises the exact same path a real
	// server payload does.
	body := "["
	for i, n := range names {
		if i > 0 {
			body += ","
		}
		body += `"` + n + `"`
	}
	body += "]"
	var sc manifest.ServiceCapabilities
	if err := sc.UnmarshalJSON([]byte(body)); err != nil {
		t.Fatalf("declaredCaps(%v): %v", names, err)
	}
	return sc
}

// qga: full known-capability ceiling, service inherits it wholesale, and
// user_namespace: false — its host-root recovery channel would otherwise be
// silently defeated the first time PrivateUsers=yes was actually enforced.
func TestRealQgaManifest_ResolvesToFullCapabilitySetAndNoUserNamespace(t *testing.T) {
	mf := loadModuleManifestYAML(t, "qemu-guest-agent")
	if len(mf.Services) != 1 || mf.Services[0].Name != "qga" {
		t.Fatalf("expected exactly one service named qga, got %+v", mf.Services)
	}

	policy := buildPolicy(mf)
	if policy.UserNamespace {
		t.Error("qga's real manifest must resolve to user_namespace: false")
	}
	if policy.Privileged {
		t.Error("qga's real manifest must NOT be privileged (see the manifest's own comment: no operator allowlist grant on every account)")
	}
	// PIN QGA CANNOT BE REFUSED (review F5): seccomp has NO full-set-style
	// exemption in applyModuleSecurityDropIns — an absent SystemCallFilter=
	// is "every syscall allowed", never equivalent to any declared profile,
	// so a seccomp_profile on qga would make it fail-closeable in a way the
	// capability/userns exemptions specifically exist to prevent. This
	// guards the manifest fact the exemptions' safety argument depends on,
	// so a future edit adding one is caught here rather than only on a live
	// node the next time its drop-in write happens to fail.
	if policy.SeccompProfile != "" {
		t.Errorf("qga's real manifest must declare NO seccomp_profile (seccomp has no fail-closed exemption); got %q", policy.SeccompProfile)
	}

	writes, err := attachCapabilityWrites(mf, policy)
	if err != nil {
		t.Fatalf("attachCapabilityWrites: %v", err)
	}
	byUnit := capsByUnit(t, writes)
	unit := lifecycle.UnitName(mf.ID, "qga")
	allow, ok := byUnit[unit]
	if !ok {
		t.Fatalf("no resolved capabilities for unit %s; got %v", unit, byUnit)
	}
	// DISTINGUISHES "this module's real declared ceiling happens to be full"
	// from "the resolver defaults every unresolved/absent ceiling to full" —
	// a mutant collapsing to the latter passes THIS assertion but fails the
	// hub-backend one below, which reads the real manifest with a narrow
	// declared ceiling through the exact same code path.
	if !security.IsFullCapabilitySet(allow) {
		t.Errorf("qga's resolved capability set is not the full known set: %v", allow)
	}
}

// hub-backend's rails-setup: a real, narrow, DECLARED ceiling (not full) —
// read through the identical resolver path as the qga test above. If a
// regression made the resolver default every module to the full set (rather
// than actually reading its declared ceiling), this test catches it even
// though the qga test alone would not.
func TestRealHubBackendManifest_RailsSetupCeilingIsNarrowNotFull(t *testing.T) {
	mf := loadModuleManifestYAML(t, "powernode-hub-backend")
	policy := buildPolicy(mf)
	writes, err := attachCapabilityWrites(mf, policy)
	if err != nil {
		t.Fatalf("attachCapabilityWrites: %v", err)
	}
	byUnit := capsByUnit(t, writes)
	unit := lifecycle.UnitName(mf.ID, "rails-setup")
	allow, ok := byUnit[unit]
	if !ok {
		t.Fatalf("no resolved capabilities for unit %s; got %v", unit, byUnit)
	}
	if len(allow) == 0 {
		t.Fatalf("expected rails-setup to have a non-empty ceiling (CAP_CHOWN/CAP_FOWNER/CAP_DAC_OVERRIDE); got none")
	}
	if security.IsFullCapabilitySet(allow) {
		t.Errorf("rails-setup's real ceiling must NOT be the full known-capability set (module ceiling vs. default-to-full-set); got %v", allow)
	}
}
