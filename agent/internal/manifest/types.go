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
//
// P8.1 lifecycle: every module ships `services` (one row per
// system_module_services). The agent's internal/lifecycle package
// writes a systemd unit per service on attach. There is no longer
// a fallback to legacy `init_start` shell strings — modules without
// a `services` array are unsupported.
type Manifest struct {
	ID                string         `json:"id"`
	Name              string         `json:"name"`
	Variety           string         `json:"variety,omitempty"` // config|instance|subscription
	Priority          int            `json:"priority"`
	EffectivePriority int            `json:"effective_priority"`
	Digest            string         `json:"digest,omitempty"` // OCI digest from current_version
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
	//   - "security": {capabilities, seccomp_profile, egress_allowlist}
	//   - "skills": []string — bound skill ids (Phase 2 reseeders)
	Config map[string]any `json:"config,omitempty"`
	// Per-service definitions. Populated from
	// system_module_services rows in the platform DB; surfaced by
	// the modules#show endpoint at /api/v1/system/node_api/modules/:id.
	// The agent's internal/lifecycle package emits one systemd unit
	// file per service at attach time and tears them down on detach.
	Services []Service `json:"services"`
}

// Service mirrors the server-side serialize_module_services payload.
// Each maps 1:1 to a system_module_services row.
//
// Lifecycle on the on-node agent (internal/lifecycle):
//   - attachModule writes /etc/systemd/system/powernode-<mod>-<name>.service
//     from these fields, runs systemctl daemon-reload + start
//   - detachModule stops + removes the unit + daemon-reload
//   - Services are started in topological order over Dependencies;
//     stopped in reverse order
type Service struct {
	Name                       string            `json:"name"`
	StartCommand               string            `json:"start_command"`
	StopCommand                string            `json:"stop_command,omitempty"`
	RestartPolicy              string            `json:"restart_policy,omitempty"` // always | on-failure | never
	User                       string            `json:"user,omitempty"`
	WorkingDirectory           string            `json:"working_directory,omitempty"`
	Env                        map[string]string `json:"env,omitempty"`
	ExposedPorts               []any             `json:"exposed_ports,omitempty"` // metadata only
	Capabilities               []string          `json:"capabilities,omitempty"`
	HealthEndpoint             string            `json:"health_endpoint,omitempty"`
	HealthMethod               string            `json:"health_method,omitempty"`
	HealthIntervalSeconds      int               `json:"health_interval_seconds,omitempty"`
	HealthTimeoutSeconds       int               `json:"health_timeout_seconds,omitempty"`
	HealthInitialDelaySeconds  int               `json:"health_initial_delay_seconds,omitempty"`
	Dependencies               []string          `json:"dependencies,omitempty"` // names of services that must start before this one
	Metadata                   map[string]any    `json:"metadata,omitempty"`
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

// UnitNames returns the canonical systemd unit names this manifest
// declares — one per service, in the order the platform emitted them
// (which is the declaration order in system_module_services). The
// agent's internal/lifecycle package handles topological start
// ordering separately; this is just the flat list.
func (m *Manifest) UnitNames() []string {
	if len(m.Services) == 0 {
		return nil
	}
	out := make([]string, 0, len(m.Services))
	for _, s := range m.Services {
		out = append(out, "powernode-"+m.ID+"-"+s.Name+".service")
	}
	return out
}
