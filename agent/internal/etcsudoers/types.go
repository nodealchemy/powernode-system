package etcsudoers

import "github.com/nodealchemy/powernode-system/agent/internal/manifest"

// Grant pairs a sudo declaration with the module name that owns it.
// The pair (ModuleName, Grant.ID) uniquely identifies the rendered
// file at /etc/sudoers.d/powernode-<ModuleName>-<Grant.ID>.
type Grant struct {
	ModuleName string
	Grant      manifest.ManifestSudoer
}

// Filename returns the basename this grant renders to under
// /etc/sudoers.d/. Format enforced by sudo's processing rules: no
// dots, no tildes, only [a-zA-Z0-9_-].
func (g Grant) Filename() string {
	return "powernode-" + g.ModuleName + "-" + g.Grant.ID
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
