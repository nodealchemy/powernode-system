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

var verifierAssignRe = regexp.MustCompile(`(?m)^\s*Verifier:\s*(.+?),\s*$`)
var fsverityAssignRe = regexp.MustCompile(`(?m)^\s*Fsverity:\s*(.+?),\s*$`)

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
// with the transport gap that makes it refuse every mount), and it fails if the
// doc's warning is removed while the wiring is unchanged (the claim is quietly
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
		if got := strings.TrimSpace(matches[0][1]); got != "verify.AlwaysOK{}" {
			t.Fatalf("%s (%s): Verifier is now %s, not verify.AlwaysOK{}.\n\n"+
				"If this is intentional, note that oci.Puller.Pull never fetches a "+
				"cosign bundle (see oci.TestPullFetchesNoCosignBundle), so a real "+
				"CosignVerifier here refuses EVERY module mount on EVERY node — on "+
				"compose.go that means an unbootable node. Work the prerequisites in "+
				"internal/verify/doc.go, then update that doc and this guard together.",
				site.path, site.what, got)
		}

		// The fs-verity arm of the same gate. Left unset, ReconcilerConfig.Fsverity
		// is nil and the check is skipped entirely.
		if m := fsverityAssignRe.FindAllStringSubmatch(src, -1); len(m) != 0 {
			t.Fatalf("%s (%s): now sets Fsverity: %s. fs-verity has a working wire "+
				"channel, so this may well be correct — but it fails closed for any "+
				"module publishing no fsverity_root_hash. Confirm population first, "+
				"and refresh internal/verify/doc.go.",
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
		"AlwaysOK",
		"missing TRANSPORT",
	} {
		if !strings.Contains(string(doc), claim) {
			t.Fatalf("internal/verify/doc.go no longer contains %q, but the wiring "+
				"above is still unenforced. The warning was removed without the "+
				"underlying gap being closed — restore it.", claim)
		}
	}
}

// TestNoFourthModuleMountVerifierSite is the equality oracle for the guard
// above, which only ever inspects a hard-coded list and would therefore not
// notice a FOURTH construction site being added.
//
// Every module mount funnels through exactly one gate — mount.MountModule has a
// single production caller, Reconciler.mountModuleArtifact — so the verifier
// that gate uses is decided entirely by which construction site built the
// Reconciler. That makes "the set of sites" a security-relevant quantity, and a
// claim about a sole chokepoint is worth exactly as much as the ratchet holding
// it. Enumerate rather than sample.
func TestNoFourthModuleMountVerifierSite(t *testing.T) {
	want := map[string]bool{
		"internal/runtime/service.go":                            true,
		"internal/runtime/compose.go":                            true,
		"cmd/powernode-agent/internal/cli/reconciler_factory.go": true,
	}

	// A file is a CHOOSING site when it (a) imports internal/verify, so its
	// Verifier: refers to this package's interface and not, say, a2a.Verifier's
	// unrelated capability-token type, and (b) assigns a value that is not simply
	// forwarded from another config struct. NewReconcilerForCLI in reconcile.go
	// satisfies (a) but only relays cfg.Verifier onward, so it decides nothing.
	//
	// The forwarding test is deliberately shape-based rather than a literal match
	// on "verify.AlwaysOK{}": a site that built its verifier through a helper
	// (Verifier: buildVerifier()) would be invisible to a literal grep while still
	// choosing, which is exactly the case this oracle exists to catch.
	const verifyImport = "powernode-system/agent/internal/verify"
	forwarded := regexp.MustCompile(`^cfg\.\w+$`)

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
		if !strings.Contains(string(b), verifyImport) {
			return nil
		}
		for _, m := range verifierAssignRe.FindAllStringSubmatch(string(b), -1) {
			if forwarded.MatchString(strings.TrimSpace(m[1])) {
				continue
			}
			rel, _ := filepath.Rel(agentRoot, p)
			got[filepath.ToSlash(rel)] = true
		}
		return nil
	})
	if err != nil {
		t.Fatalf("walk %s: %v", agentRoot, err)
	}

	for p := range got {
		if !want[p] {
			t.Errorf("NEW module-mount Verifier construction site: %s\n"+
				"Every module mount funnels through Reconciler.mountModuleArtifact, so "+
				"this site decides whether that mount is verified. Add it to "+
				"moduleMountConstructionSites and account for it in "+
				"internal/verify/doc.go.", p)
		}
	}
	for p := range want {
		if !got[p] {
			t.Errorf("expected module-mount Verifier construction site %s is gone or "+
				"no longer assigns Verifier: — the wiring moved; re-derive the set and "+
				"refresh internal/verify/doc.go.", p)
		}
	}
}
