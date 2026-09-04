package runtime

import (
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/verify"
)

// The three production sites that build a Reconciler and therefore decide what
// verifies a module artifact before it is loop-mounted, with the verify.Site
// each must resolve its verifier for. Paths are relative to this package
// directory (where `go test` runs).
var moduleMountConstructionSites = []struct {
	path string
	what string
	site string
}{
	{"service.go", "the long-lived 60s reconcile loop", "verify.SiteService"},
	{"compose.go", "NewPivotComposerAt, the direct_kernel boot composer", "verify.SiteBoot"},
	{"../../cmd/powernode-agent/internal/cli/reconciler_factory.go", "BuildReconciler, for attach/update/sync/detach", "verify.SiteCLI"},
}

// verifierAssignRe captures the REST OF THE LINE after a Verifier: field, not a
// comma-terminated value. Requiring `,\s*$` made two gofmt-legal, semantically
// null edits break the guard: a trailing `// comment` after the value stopped
// matching at all (reported as "the wiring moved" when it had not), and a
// two-fields-on-one-line literal let a lazy capture swallow the next field
// (reported as a changed Verifier, i.e. a security change that never happened).
// Callers below test the captured text by CONTAINMENT for that reason.
var verifierAssignRe = regexp.MustCompile(`(?m)^[ \t]*Verifier:[ \t]*(.+)$`)
var fsverityAssignRe = regexp.MustCompile(`(?m)^[ \t]*Fsverity:[ \t]*(.+)$`)

// concreteVerifierRe matches construction of any concrete implementation of the
// Verifier interface — package-qualified from outside internal/verify, bare
// from inside it. This, not the field name, is what the enumeration oracle
// keys on — see its comment.
var concreteVerifierRe = regexp.MustCompile(`(?:\bverify\.|[&\s(,])(AlwaysOK|CosignVerifier|AuditVerifier)\{`)

// TestModuleMountVerifierWiringIsConfigDriven pins the central factual claim in
// internal/verify/doc.go: every production path that mounts a module artifact
// obtains its Verifier from ResolveModuleVerifier for its own verify.Site, and
// nowhere constructs a concrete verifier itself. What that resolver returns is
// pinned behaviourally by TestResolveModuleVerifierOffNeverTouchesTheNetwork
// (the DEFAULT is verify.AlwaysOK) and verify.TestNewModuleVerifierEnforcementLadder.
//
// This is a source-shape guard on purpose. The property is package-level
// WIRING, not behaviour reachable from a constructed Reconciler — NewReconciler
// happily accepts any Verifier, and every existing test supplies AlwaysOK
// itself, so no behavioural test in this package can observe which verifier
// production actually chose. Reading the construction sites is the only
// instrument that can.
//
// It is a two-sided guard. It fails if a site stops going through the resolver
// (someone hard-wires AlwaysOK back, or hard-wires a real CosignVerifier —
// which on compose.go would refuse every mount on an unsigned fleet and make
// the node unbootable), and it fails if the doc's DEFAULT OFF statement is
// removed while the wiring still defaults off. Either failure is a prompt to
// update both together, not to relax the assertion.
func TestModuleMountVerifierWiringIsConfigDriven(t *testing.T) {
	for _, site := range moduleMountConstructionSites {
		b, err := os.ReadFile(site.path)
		if err != nil {
			t.Fatalf("read %s (%s): %v — if this file moved, update "+
				"moduleMountConstructionSites AND internal/verify/doc.go together",
				site.path, site.what, err)
		}
		src := string(b)

		matches := verifierAssignRe.FindAllStringSubmatch(src, -1)
		if len(matches) != 1 {
			t.Fatalf("%s (%s): found %d `Verifier:` assignments, want exactly 1. "+
				"A construction site was added or removed; re-check every module-mount "+
				"path and refresh internal/verify/doc.go",
				site.path, site.what, len(matches))
		}
		if line := matches[0][1]; concreteVerifierRe.MatchString(line) {
			t.Fatalf("%s (%s): Verifier line %q constructs a concrete verifier "+
				"directly. Every mount site must take its verifier from "+
				"ResolveModuleVerifier so the operator's module-signing policy (DEFAULT "+
				"OFF; ladder off/audit/runtime/all) is what decides — a hard-wired "+
				"CosignVerifier refuses every unsigned mount, which on compose.go is an "+
				"unbootable node; a hard-wired AlwaysOK silently disables an opted-in "+
				"policy.", site.path, site.what, strings.TrimSpace(line))
		}
		if !strings.Contains(src, "ResolveModuleVerifier(") || !strings.Contains(src, site.site) {
			t.Fatalf("%s (%s): must resolve its verifier via ResolveModuleVerifier(..., %s, ...)",
				site.path, site.what, site.site)
		}

		// The fs-verity arm of the same gate. Left unset, ReconcilerConfig.Fsverity
		// is nil and the check is skipped entirely.
		if m := fsverityAssignRe.FindAllStringSubmatch(src, -1); len(m) != 0 {
			t.Fatalf("%s (%s): now sets Fsverity: %s. The fsverity_root_hash channel "+
				"is complete only when every publisher stamps a root — a module with a "+
				"nil root hash hits the fail-closed branch. Confirm population first, "+
				"and refresh internal/verify/doc.go.",
				site.path, site.what, strings.TrimSpace(m[0][1]))
		}
	}

	// Presence half: the doc must still carry the claims these sites justify.
	doc, err := os.ReadFile("../verify/doc.go")
	if err != nil {
		t.Fatalf("read internal/verify/doc.go: %v", err)
	}
	for _, claim := range []string{"DEFAULT OFF", "ResolveModuleVerifier", "NewModuleVerifier", "sign-blob"} {
		if !strings.Contains(string(doc), claim) {
			t.Fatalf("internal/verify/doc.go no longer contains %q, but the wiring "+
				"above still resolves through the policy whose default is off. The "+
				"map was edited without the wiring changing — restore it.", claim)
		}
	}
}

// The DEFAULT-OFF property, asserted behaviourally through the same resolver
// every site calls: with the zero policy the resolver returns AlwaysOK and
// performs no I/O. TestResolveModuleVerifierOffNeverTouchesTheNetwork covers
// the network half; this pins the type at each site, so a future default
// change is a visible test edit.
func TestResolveModuleVerifierDefaultIsAlwaysOKAtEverySite(t *testing.T) {
	for _, site := range []verify.Site{verify.SiteService, verify.SiteCLI, verify.SiteBoot} {
		v, err := ResolveModuleVerifier(verify.ModuleSigningConfig{}, site, nil, &mount.RecorderRunner{}, "", nil)
		if err != nil {
			t.Fatalf("%s: %v", site, err)
		}
		if _, ok := v.(verify.AlwaysOK); !ok {
			t.Fatalf("%s: default must be verify.AlwaysOK, got %T", site, v)
		}
	}
}

// Every place in the agent that constructs a concrete Verifier implementation,
// with what it is for. The three module-mount sites are listed because their
// reconciler-config literal names a Verifier (see the enumeration rule below),
// even though they construct nothing themselves.
var concreteVerifierSites = map[string]string{
	"internal/runtime/service.go":                            "module mount — resolved via ResolveModuleVerifier(SiteService), DEFAULT OFF",
	"internal/runtime/compose.go":                            "module mount — resolved via ResolveModuleVerifier(SiteBoot), DEFAULT OFF; enforces only under `all`",
	"cmd/powernode-agent/internal/cli/reconciler_factory.go": "module mount — resolved via ResolveModuleVerifier(SiteCLI), DEFAULT OFF",
	"internal/runtime/module_signing.go":                     "ResolveModuleVerifier — the policy resolver; constructs AlwaysOK for off and for the non-enforcing no-anchor degrade",
	"internal/verify/module.go":                              "NewModuleVerifier — THE constructor: AlwaysOK for off, static-key CosignVerifier (+AuditVerifier wrapper) otherwise",
	"internal/bootupgrade/bootupgrade.go":                    "boot/UKI upgrade — REAL CosignVerifier, static-key, ENFORCED, key inline on the task",
	"cmd/powernode-agent/internal/cli/verify_cmd.go":         "operator `powernode-agent verify` — keyless pins constructed here; --key goes through NewModuleVerifier",
}

// TestConcreteVerifierSitesAreEnumerated is the equality oracle for the guard
// above, which only inspects a hard-coded list of three files and would not
// notice a FOURTH mount site being added.
//
// It keys on the CONSTRUCTION of a concrete Verifier implementation rather than
// on the `Verifier:` field name, because two earlier framings each let a real
// choosing site through. Requiring the constructing file to mention the verify
// import missed a site whose verifier came from a helper in a SIBLING file of
// the same package. Excluding values shaped like `cfg.Verifier` as mere
// forwarding missed a site that defaulted `cfg.Verifier` to a real
// CosignVerifier before passing it on — including, notably, doing exactly that
// inside reconcile.go's own NewReconciler, which the forwarding rule had
// already excluded from view.
//
// Keying on the construction catches both: whatever indirection carries a
// verifier to the config literal, some file has to name the type — including,
// now, the two files that do so on every site's behalf (verify/module.go and
// runtime/module_signing.go). The regexp matches bare construction inside
// internal/verify as well as the qualified form outside it, so the constructor
// cannot hide in its own package.
func TestConcreteVerifierSitesAreEnumerated(t *testing.T) {
	agentRoot := "../.."
	got := map[string]bool{}
	err := filepath.WalkDir(agentRoot, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if name := d.Name(); name == "vendor" || name == "testdata" || name == ".git" {
				return fs.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(p, ".go") || strings.HasSuffix(p, "_test.go") {
			return nil
		}
		b, rerr := os.ReadFile(p)
		if rerr != nil {
			return rerr
		}
		// A file counts if it constructs a concrete verifier, OR if it builds a
		// RECONCILER config literal whose Verifier: is not plainly forwarded from
		// another config struct — the latter catches a config literal fed by a
		// helper. The reconciler-config condition is what keeps unrelated types
		// out: internal/a2a/server.go assigns `Verifier: verifier` on its own
		// Server struct, for a capability-token verifier that has nothing to do
		// with artifact signatures.
		src := string(b)
		hit := concreteVerifierRe.Match(b)
		if !hit && (strings.Contains(src, "ReconcilerConfig{") || strings.Contains(src, "FactoryConfig{")) {
			for _, m := range verifierAssignRe.FindAllStringSubmatch(src, -1) {
				v := strings.TrimSpace(strings.TrimSuffix(strings.TrimSpace(m[1]), ","))
				if !strings.HasPrefix(v, "cfg.") {
					hit = true
					break
				}
			}
		}
		if hit {
			rel, _ := filepath.Rel(agentRoot, p)
			got[filepath.ToSlash(rel)] = true
		}
		return nil
	})
	if err != nil {
		t.Fatalf("walk %s: %v", agentRoot, err)
	}

	for p := range got {
		if _, ok := concreteVerifierSites[p]; !ok {
			t.Errorf("NEW concrete Verifier construction site: %s\n"+
				"If it feeds a Reconciler it decides whether a module mount is "+
				"verified — every mount funnels through "+
				"Reconciler.mountModuleArtifact and must resolve through "+
				"ResolveModuleVerifier. Add it to concreteVerifierSites, to "+
				"moduleMountConstructionSites if it is a mount path, and account for "+
				"it in internal/verify/doc.go.", p)
		}
	}
	for p, what := range concreteVerifierSites {
		if !got[p] {
			t.Errorf("expected Verifier construction site %s (%s) no longer "+
				"constructs one — the wiring moved; re-derive the set and refresh "+
				"internal/verify/doc.go.", p, what)
		}
	}
}
