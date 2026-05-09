// Package manifest is the agent-side typed view of a NodeModule's
// manifest. Mirrors what the platform serializes via
// `NodeModule#serialize_module_full` (extensions/system/server/app/
// models/system/node_module.rb).
//
// The agent caches manifests under
// /persist/var/lib/powernode/modules/<id>/manifest.json so subsequent
// CLI invocations (init, detach) work without a platform round-trip.
//
// Reference: ManifestImportService.apply_to_module describes the
// canonical schema; this package keeps Go types in sync with that.
package manifest

// Manifest is the typed view the agent operates on. Field names
// follow the platform's JSON shape (snake_case) so the unmarshal
// from /node_api/modules/:id is direct.
type Manifest struct {
	ID                string         `json:"id"`
	Name              string         `json:"name"`
	Variety           string         `json:"variety,omitempty"` // config|instance|subscription
	Priority          int            `json:"priority"`
	EffectivePriority int            `json:"effective_priority"`
	Digest            string         `json:"digest,omitempty"` // OCI digest from current_version
	InitStart         string         `json:"init_start,omitempty"`
	InitStop          string         `json:"init_stop,omitempty"`
	InitRestart       string         `json:"init_restart,omitempty"`
	RebootRequired    bool           `json:"reboot_required,omitempty"`
	DataFileName      string         `json:"data_file_name,omitempty"`
	DataChecksum      string         `json:"data_checksum,omitempty"`
	CopyPath          *CopyPath      `json:"copy_path,omitempty"`
	PuppetModules     []PuppetModule `json:"puppet_modules,omitempty"`
	// Spec arrays are stored base64-encoded server-side but the JSON
	// response decodes them into plain string arrays.
	Mask           []string `json:"mask,omitempty"`
	FileSpec       []string `json:"file_spec,omitempty"`
	DependencySpec []string `json:"dependency_spec,omitempty"`
	ProtectedSpec  []string `json:"protected_spec,omitempty"`
	// Config is the free-form JSON blob. Known keys include:
	//   - "units": []string  — preferred systemd unit list (for init/attach)
	//   - "security": {capabilities, seccomp_profile, egress_allowlist}
	//   - "skills": []string — bound skill ids (Phase 2 reseeders)
	Config map[string]any `json:"config,omitempty"`
}

// CopyPath describes a file or directory to copy from the module
// blob into the running rootfs at attach time. Mirrors the
// CopyPath model server-side.
type CopyPath struct {
	ID                  string `json:"id,omitempty"`
	Name                string `json:"name,omitempty"`
	SourcePath          string `json:"source_path,omitempty"`
	DestinationPath     string `json:"destination_path,omitempty"`
	Recursive           bool   `json:"recursive,omitempty"`
	PreservePermissions bool   `json:"preserve_permissions,omitempty"`
}

// PuppetModule identifies a Puppet manifest module attached to this
// NodeModule. The agent's puppet apply CLI fetches each by id.
type PuppetModule struct {
	ID   string `json:"id,omitempty"`
	Name string `json:"name,omitempty"`
}

// Units returns the canonical systemd unit list for this manifest.
// Prefer Config["units"] when set (M2-era explicit declaration);
// fall back to single-unit legacy parsing of InitStart for back-compat
// with modules authored before the structured Units field.
func (m *Manifest) Units() []string {
	if raw, ok := m.Config["units"]; ok {
		if arr, ok := raw.([]any); ok {
			out := make([]string, 0, len(arr))
			for _, v := range arr {
				if s, ok := v.(string); ok && s != "" {
					out = append(out, s)
				}
			}
			return out
		}
	}
	// Fallback: parse legacy init_start text. Recognized form is
	// `systemctl <verb> <unit>` for a single unit. Anything else
	// returns nil — callers must handle the empty case explicitly.
	return parseSingleUnit(m.InitStart)
}
