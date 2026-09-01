package runtime

import (
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// The three production sites that build a Reconciler and therefore decide what
// verifies a module artifact before it is loop-mounted. Paths are relative to
// this package directory (where `go test` runs).
var moduleMountConstructionSites = []struct {
	path string
	what string
}{
	{"service.go", "the long-lived 60s reconcile loop"},
	{"compose.go", "NewPivotComposerAt, the direct_kernel boot composer"},
	{"../../cmd/powernode-agent/internal/cli/reconciler_factory.go", "BuildReconciler, for attach/update/sync/detach"},
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

// alwaysOKRe matches the no-op verifier's construction anywhere in a line.
var alwaysOKRe = regexp.MustCompile(`\bverify\.AlwaysOK\{\}`)

// concreteVerifierRe matches construction of any concrete implementation of the
// Verifier interface. This, not the field name, is what the oracle below keys
// on — see its comment.
var concreteVerifierRe = regexp.MustCompile(`\bverify\.(AlwaysOK|CosignVerifier)\{`)

// TestModuleMountVerifierWiringIsUnenforced pins the central factual claim in
// internal/verify/doc.go: every production path that mounts a module artifact
// is wired with the no-op verify.AlwaysOK, so module signature verification is
// not enforced anywhere on the node.
//
// This is a source-shape guard on purpose. The property is package-level
// WIRING, not behaviour reachable from a constructed Reconciler — NewReconciler
// happily accepts any Verifier, and every existing test supplies AlwaysOK
// itself, so no behavioural test in this package can observe which verifier
// production actually chose. Reading the construction sites is the only
// instrument that can.
//
// It is deliberately a two-sided guard. It fails if the wiring changes while
// the doc still says it has not (someone enables enforcement without reckoning
// with the gap that makes it refuse every mount), and it fails if the doc's
// warning is removed while the wiring is unchanged (the claim is quietly
// deleted rather than earned). Either failure is a prompt to update both
// together, not to relax the assertion.
func TestModuleMountVerifierWiringIsUnenforced(t *testing.T) {
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
		// Containment, not equality: tolerate a trailing comment or a neighbouring
		// field on the same line, both of which leave the wiring identical.
		if line := matches[0][1]; !alwaysOKRe.MatchString(line) {
			t.Fatalf("%s (%s): Verifier line is now %q, which does not construct "+
				"verify.AlwaysOK{}.\n\n"+
				"If this is intentional, note that the platform signs modules with "+
				"`cosign sign` over an OCI ref, while Verifier.VerifyBlob wants a "+
				"sign-blob bundle over local bytes that oci.Puller.Pull never fetches "+
				"(see oci.TestPullFetchesNoCosignBundle). A real CosignVerifier here "+
				"refuses EVERY module mount on EVERY node — on compose.go that means "+
				"an unbootable node. Work the prerequisites in internal/verify/doc.go, "+
				"then update that doc and this guard together.",
				site.path, site.what, strings.TrimSpace(line))
		}

		// The fs-verity arm of the same gate. Left unset, ReconcilerConfig.Fsverity
		// is nil and the check is skipped entirely.
		if m := fsverityAssignRe.FindAllStringSubmatch(src, -1); len(m) != 0 {
			t.Fatalf("%s (%s): now sets Fsverity: %s. The fsverity_root_hash channel "+
				"is complete only on the native publish path — modules published via "+
				"ingest! carry a nil root hash, and this gate fails closed on those. "+
				"Confirm population first, and refresh internal/verify/doc.go.",
				site.path, site.what, strings.TrimSpace(m[0][1]))
		}
	}

	// Presence half: the doc must still carry the warning these sites justify.
	doc, err := os.ReadFile("../verify/doc.go")
	if err != nil {
		t.Fatalf("read internal/verify/doc.go: %v", err)
	}
	for _, claim := range []string{
		"NOT ENFORCED",
		// The two independent blockers. "WRONG SUBJECT" is the load-bearing one:
		// the platform signs an OCI image ref, while Verifier.VerifyBlob wants a
		// sign-blob bundle over local bytes, so no amount of transport work alone
		// closes this. An earlier revision of the doc named only the transport
		// half, and this anchor was updated with it rather than around it.
		"WRONG SUBJECT",
		"no transport delivers signature material",
	} {
		if !strings.Contains(string(doc), claim) {
			t.Fatalf("internal/verify/doc.go no longer contains %q, but the wiring "+
				"above is still unenforced. The warning was removed without the "+
				"underlying gap being closed — restore it.", claim)
		}
	}
}

// Every place in the agent that constructs a concrete Verifier implementation,
// with what it is for. Three wire the no-op onto a module mount; two construct
// a real CosignVerifier on paths that do not mount modules.
var concreteVerifierSites = map[string]string{
	"internal/runtime/service.go":                            "module mount — AlwaysOK, the long-lived 60s reconcile loop",
	"internal/runtime/compose.go":                            "module mount — AlwaysOK, the direct_kernel boot composer",
	"cmd/powernode-agent/internal/cli/reconciler_factory.go": "module mount — AlwaysOK, attach/update/sync/detach",
	"internal/bootupgrade/bootupgrade.go":                    "boot/UKI upgrade — REAL CosignVerifier, static-key, ENFORCED",
	"cmd/powernode-agent/internal/cli/verify_cmd.go":         "operator `powernode-agent verify` — REAL CosignVerifier, keyless only",
}

// TestConcreteVerifierSitesAreEnumerated is the equality oracle for the guard
// above, which only inspects a hard-coded list of three files and would not
// notice a FOURTH site being added.
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
// verifier to the config literal, some file has to name the type. It also
// brings the two real-CosignVerifier sites into scope, which the field-name
// framing never saw, so this enumerates the agent's whole verifier landscape
// rather than just its module-mount corner.
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
				"Reconciler.mountModuleArtifact. Add it to concreteVerifierSites, to "+
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
