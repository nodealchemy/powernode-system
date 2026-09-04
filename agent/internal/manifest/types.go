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

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
)

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
	ID                string `json:"id"`
	Name              string `json:"name"`
	Variety           string `json:"variety,omitempty"` // config|instance|subscription
	Priority          int    `json:"priority"`
	EffectivePriority int    `json:"effective_priority"`
	Digest            string `json:"digest,omitempty"` // OCI layer digest of the erofs blob
	// FsverityRootHash is the fs-verity Merkle root of the erofs blob
	// the agent will pull. Anchors the on-node read path.
	FsverityRootHash string         `json:"fsverity_root_hash,omitempty"`
	RebootRequired   bool           `json:"reboot_required,omitempty"`
	DataFileName     string         `json:"data_file_name,omitempty"`
	DataChecksum     string         `json:"data_checksum,omitempty"`
	CopyPath         *CopyPath      `json:"copy_path,omitempty"`
	PuppetModules    []PuppetModule `json:"puppet_modules,omitempty"`
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

	// Fleet-managed Unix identities declared by this module's
	// manifest's users:/groups: blocks (plus any auto-allocated
	// same-name primary groups). The agent's internal/etcidentity
	// package unions these across all installed modules to render
	// /etc/passwd, /etc/group, /etc/shadow, /etc/gshadow.
	//
	// Fields use embedded types from internal/etcidentity to avoid an
	// import cycle — etcidentity imports manifest, not the other way.
	// Mirrored manually here to keep the dependency direction clean.
	Users   []ManifestUser   `json:"users,omitempty"`
	Groups  []ManifestGroup  `json:"groups,omitempty"`
	Sudoers []ManifestSudoer `json:"sudoers,omitempty"`
}

// ManifestUser mirrors the platform's serialize_module_users payload.
// Kept here (not in internal/etcidentity) to preserve the
// manifest → etcidentity import direction.
type ManifestUser struct {
	Name                string   `json:"name"`
	UID                 int      `json:"uid"`
	PrimaryGID          int      `json:"primary_gid"`
	PrimaryGroup        string   `json:"primary_group"`
	Shell               string   `json:"shell"`
	Home                string   `json:"home"`
	Gecos               string   `json:"gecos"`
	SupplementaryGroups []string `json:"supplementary_groups,omitempty"`
}

// ManifestGroup mirrors the platform's serialize_module_groups payload.
type ManifestGroup struct {
	Name    string   `json:"name"`
	GID     int      `json:"gid"`
	Members []string `json:"members,omitempty"`
}

// ManifestSudoer mirrors the platform's serialize_module_sudoers payload.
// One row per declared sudo grant. The agent's internal/etcsudoers
// package validates each via visudo -cf and writes one
// /etc/sudoers.d/powernode-<module>-<id> file per grant.
type ManifestSudoer struct {
	ID         string   `json:"id"`
	User       string   `json:"user"`
	RunasUser  string   `json:"runas_user"`
	RunasGroup string   `json:"runas_group,omitempty"`
	Commands   []string `json:"commands"`
	Flags      []string `json:"flags,omitempty"`
}

// Service mirrors the server-side serialize_module_services payload.
// Each maps 1:1 to a system_module_services row.
//
// Lifecycle on the on-node agent (internal/lifecycle):
//   - attachModuleServices writes /etc/systemd/system/powernode-<mod>-<name>.service
//     from these fields, runs systemctl daemon-reload + start
//   - detachModule stops + removes the unit + daemon-reload
//   - Services are started in topological order over
//     ResolvedDependencyEdges() (the same graph the unit renderer walks);
//     stopped in reverse order
type Service struct {
	Name         string `json:"name"`
	StartCommand string `json:"start_command"`
	// UnitBody is a verbatim systemd unit file body (option A2),
	// mutually exclusive with StartCommand. RenderUnitMode passes it
	// through as-is (plus an appended generated [Unit] dependency
	// section, and — under chroot — an appended [Service] chroot
	// section) instead of synthesizing ExecStart=/Restart=/etc. from
	// the structured fields below. omitempty is LOAD-BEARING: it keeps
	// ServicesHash byte-identical for every existing (non-unit_body)
	// service, so this addition doesn't trigger a fleet-wide re-attach.
	UnitBody                  string            `json:"unit_body,omitempty"`
	StopCommand               string            `json:"stop_command,omitempty"`
	RestartPolicy             string            `json:"restart_policy,omitempty"` // always | on-failure | never
	User                      string            `json:"user,omitempty"`
	WorkingDirectory          string            `json:"working_directory,omitempty"`
	Env                       map[string]string `json:"env,omitempty"`
	ExposedPorts              []any             `json:"exposed_ports,omitempty"` // metadata only
	Capabilities              []string          `json:"capabilities,omitempty"`
	HealthEndpoint            string            `json:"health_endpoint,omitempty"`
	HealthMethod              string            `json:"health_method,omitempty"`
	HealthIntervalSeconds     int               `json:"health_interval_seconds,omitempty"`
	HealthTimeoutSeconds      int               `json:"health_timeout_seconds,omitempty"`
	HealthInitialDelaySeconds int               `json:"health_initial_delay_seconds,omitempty"`
	Dependencies              []string          `json:"dependencies,omitempty"` // names of services that must start before this one
	// DependencyEdges carries the same edges as Dependencies plus each
	// edge's KIND, which decides whether the rendered unit gets a hard
	// Requires= or a best-effort Wants= (see lifecycle.writeDependencyDirectives).
	//
	// Additive on purpose. `dependencies` (names only) stays on the wire
	// unchanged so an agent older than this field keeps working against a
	// server that emits both, and this agent keeps working against a server
	// that emits only `dependencies` — see ResolvedDependencyEdges. omitempty
	// is LOAD-BEARING for the same reason it is on UnitBody: a service with
	// no dependencies hashes byte-identically to before, so ServicesHash does
	// not churn fleet-wide. Services that DO declare dependencies re-attach
	// once, which is the intended effect of shipping a corrected renderer.
	DependencyEdges []DependencyEdge `json:"dependency_edges,omitempty"`
	Metadata        map[string]any   `json:"metadata,omitempty"`
}

// Dependency kinds, mirroring System::ModuleServiceDependency::KINDS
// (server/app/models/system/module_service_dependency.rb). The model is
// the specification; these constants must not drift from it.
const (
	// DependencyKindStartBefore: target must be running before source starts.
	DependencyKindStartBefore = "start_before"
	// DependencyKindRequiresHealth: target must pass its health check first.
	DependencyKindRequiresHealth = "requires_health"
	// DependencyKindSoftdep: target preferred-running but NOT required.
	DependencyKindSoftdep = "softdep"

	// DefaultDependencyKind is assumed for an edge that arrives without a
	// kind — i.e. from the legacy names-only `dependencies` field. It matches
	// the server's own import default (ManifestImportService uses
	// `dep.fetch("kind", "requires_health")`) and renders to the strict
	// Requires= form, so a payload with no kinds behaves exactly as it did
	// before DependencyEdges existed.
	DefaultDependencyKind = DependencyKindRequiresHealth
)

// DependencyEdge is one kind-carrying dependency edge between two services
// of the SAME module. Service names the depended-on service (matching a
// sibling Service.Name); Kind is one of the DependencyKind* constants.
type DependencyEdge struct {
	Service string `json:"service"`
	Kind    string `json:"kind,omitempty"`
}

// ResolvedDependencyEdges returns this service's dependency edges with kinds
// attached, reconciling the two wire representations:
//
//   - DependencyEdges present (server new enough to emit kinds) — used as-is,
//     with an empty Kind defaulted to DefaultDependencyKind.
//   - DependencyEdges absent (older server, or a hand-written manifest that
//     only lists names) — synthesized from Dependencies at DefaultDependencyKind.
//
// It deliberately does NOT merge the two: when the kind-bearing field is
// present it is authoritative, so a server that drops an edge from
// dependency_edges drops it from the rendered unit too rather than having a
// stale name in `dependencies` silently resurrect it as a hard requirement.
func (s Service) ResolvedDependencyEdges() []DependencyEdge {
	if len(s.DependencyEdges) > 0 {
		out := make([]DependencyEdge, 0, len(s.DependencyEdges))
		for _, e := range s.DependencyEdges {
			if e.Kind == "" {
				e.Kind = DefaultDependencyKind
			}
			out = append(out, e)
		}
		return out
	}
	if len(s.Dependencies) == 0 {
		return nil
	}
	out := make([]DependencyEdge, 0, len(s.Dependencies))
	for _, name := range s.Dependencies {
		out = append(out, DependencyEdge{Service: name, Kind: DefaultDependencyKind})
	}
	return out
}

// ServicesHash returns a stable SHA256 hash of the manifest's services
// block, suitable for change-detection. The reconciler compares this to
// State.LastAttachedManifestHashes[moduleID] each cycle to decide
// whether an already-attached module needs its systemd units re-rendered.
// AttachServices is already idempotent on unchanged content, so a
// mismatch here only triggers cheap no-op work when fields are identical
// — the value of the hash is making the per-cycle "should I even bother?"
// check O(1) instead of forcing a full re-render to discover that.
//
// JSON serialization order is stable because Go's encoding/json emits
// struct fields in declaration order. We deliberately hash the JSON
// (not a struct-field walk) so an upstream schema addition to Service
// without an agent-side type bump just shows up as a different hash
// once — re-attach happens once on first sight, then quiets down.
//
// Empty (no-services) manifests get a deterministic empty-array hash
// rather than empty-string so re-attach fires once when services land.
func (m *Manifest) ServicesHash() string {
	if m == nil {
		return ""
	}
	svcs := m.Services
	if svcs == nil {
		svcs = []Service{}
	}
	body, err := json.Marshal(svcs)
	if err != nil {
		// Unreachable under encoding/json's panic-free Marshal of basic
		// types, but return empty rather than crash if it ever happens.
		return ""
	}
	sum := sha256.Sum256(body)
	return hex.EncodeToString(sum[:])
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
