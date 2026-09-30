package etcsudoers

import (
	"fmt"
	"path/filepath"
	"regexp"

	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
)

// Grant pairs a sudo declaration with the module name that owns it.
// The pair (ModuleName, Grant.ID) uniquely identifies the rendered
// file at /etc/sudoers.d/powernode-<ModuleName>-<Grant.ID>.
type Grant struct {
	ModuleName string
	Grant      manifest.ManifestSudoer
}

// filenameComponentRE is the only shape a module name or grant id may take
// inside a drop-in basename. Go's `$` (no (?m)) anchors at end of text only, so
// a trailing newline does not slip past it. The server-side manifest validator
// (System::SudoersGrant::FILENAME_COMPONENT_RX) states the same rule.
var filenameComponentRE = regexp.MustCompile(`^[a-zA-Z0-9_-]+$`)

// maxFilenameLen caps the whole basename, comfortably under NAME_MAX (255)
// once AtomicWrite's ".fsutil-*" temp sibling is created beside it.
const maxFilenameLen = 200

// Filename returns the basename this grant renders to under
// /etc/sudoers.d/. Format enforced by sudo's processing rules: no
// dots, no tildes, only [a-zA-Z0-9_-]. It does NOT validate: a caller
// about to touch the filesystem must go through CheckFilename / PathIn.
func (g Grant) Filename() string {
	return ManagedPrefix + g.ModuleName + "-" + g.Grant.ID
}

// CheckFilename refuses a grant whose module name or id is not a plain
// [a-zA-Z0-9_-]+ token, whose basename is over-long, or whose basename is the
// break-glass drop-in's (a manifest grant must never replace that file, which
// the sweep deliberately leaves alone).
func (g Grant) CheckFilename() error {
	if !filenameComponentRE.MatchString(g.ModuleName) {
		return fmt.Errorf("module name %q is not a valid sudoers drop-in component (must match %s)", g.ModuleName, filenameComponentRE)
	}
	if !filenameComponentRE.MatchString(g.Grant.ID) {
		return fmt.Errorf("grant id %q (module %q) is not a valid sudoers drop-in component (must match %s)", g.Grant.ID, g.ModuleName, filenameComponentRE)
	}
	name := g.Filename()
	if len(name) > maxFilenameLen {
		return fmt.Errorf("sudoers drop-in name for module %q grant %q is %d bytes, over the %d cap", g.ModuleName, g.Grant.ID, len(name), maxFilenameLen)
	}
	if name == OperatorBreakGlassFilename {
		return fmt.Errorf("module %q grant %q would render to the reserved break-glass drop-in %s", g.ModuleName, g.Grant.ID, name)
	}
	return nil
}

// PathIn validates the grant and returns the file it renders to under dir,
// asserting the result is a DIRECT child of dir. Every writer of a grant file
// goes through here, before anything is rendered or written.
func (g Grant) PathIn(dir string) (string, error) {
	if err := g.CheckFilename(); err != nil {
		return "", err
	}
	return childOf(dir, g.Filename())
}

// childOf joins name under dir and asserts the result is a direct child: the
// basename survives unchanged and the parent is exactly dir. A belt over the
// component rule for the writer, and the only path the sweep unlinks by.
func childOf(dir, name string) (string, error) {
	p := filepath.Join(dir, name)
	if name == "" || filepath.Base(p) != name || filepath.Dir(p) != filepath.Clean(dir) {
		return "", fmt.Errorf("%q is not a direct child of %s", name, dir)
	}
	return p, nil
}

// CollectFromManifests flattens all declared sudo grants across the
// supplied manifests into a single slice, preserving (ModuleName,
// GrantID) order. The caller passes this directly to Apply.
func CollectFromManifests(manifests []*manifest.Manifest) []Grant {
	out := []Grant{}
	for _, m := range manifests {
		if m == nil {
			continue
		}
		for _, s := range m.Sudoers {
			out = append(out, Grant{ModuleName: m.Name, Grant: s})
		}
	}
	return out
}
