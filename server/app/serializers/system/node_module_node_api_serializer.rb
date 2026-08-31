# frozen_string_literal: true

module System
  # Node-API-facing serializer for NodeModule. Renders the module payloads
  # the on-node Go agent consumes from /api/v1/system/node_api/modules
  # (index summary, show full manifest, download file block).
  #
  # Extracted verbatim from Api::V1::System::NodeApi::ModulesController to
  # keep the controller under the size budget; the method bodies are an
  # exact move — no behavior change.
  class NodeModuleNodeApiSerializer
    def initialize(node_module)
      @module = node_module
    end

    # Index summary shape (formerly ModulesController#serialize_module).
    def summary
      serialize_module(@module)
    end

    # Full manifest shape (formerly ModulesController#serialize_module_full).
    def full
      serialize_module_full(@module)
    end

    # `file` block for modules/:id/download
    # (formerly ModulesController#build_file_payload).
    def file_payload(artifact)
      build_file_payload(@module, artifact)
    end

    private

    # Builds the `file` block of the modules/:id/download response.
    # `name` and `download_url` are derived from the module (its name and
    # id); `size`, `checksum`, and `content_type` come straight off the M1
    # OCI artifact hash. The pre-M1 data_file metadata is no longer read.
    # The agent's oci.Puller consumes this for streaming + sha256
    # verification.
    def build_file_payload(mod, artifact)
      digest = artifact["oci_digest"].to_s
      {
        name: "#{mod.name}.erofs",
        size: artifact["size"].to_i,
        checksum: digest.sub(/^sha256:/, ""),
        download_url: "/api/v1/system/node_api/files/modules/#{mod.id}",
        content_type: artifact["media_type"]
      }.compact
    end

    def serialize_module(mod)
      {
        id: mod.id,
        name: mod.name,
        variety: mod.variety,
        priority: mod.priority,
        effective_priority: mod.effective_priority,
        category_id: mod.category_id,
        # Dependant identity — non-nil when this module is a config /
        # instance override of another module. The agent uses this to
        # know which mounts belong to which subscription chain.
        parent_module_id: mod.parent_module_id,
        # P8.1: lifecycle is driven by system_module_services rows
        # (surfaced via #serialize_module_services in the show
        # response). The legacy init_start/init_stop/init_restart
        # operator-supplied shell strings are no longer consumed by
        # the on-node agent.
        reboot_required: mod.reboot_required,
        # Copy-path destination if set — agent writes this module's
        # data file into <destination_path> at attach time.
        copy_path_destination: mod.copy_path&.destination_path,
        # has_data_file is the agent reconciler's gate for "this module
        # has a blob to mount" (reconcile.go: `if !mod.HasDataFile { continue }`).
        # Truthy iff the current version has been published in at least
        # one supported format (composefs / squashfs).
        has_data_file: mod.current_version&.artifacts.present? || false,
        current_version: mod.current_version_number,
        dependencies: mod.dependencies.map(&:id)
      }
    end

    def serialize_module_full(mod)
      artifact = mod.current_version&.artifact

      serialize_module(mod).merge(
        description: mod.description,
        # All five spec fields — base64-encoded jsonb arrays. The
        # agent's rsync filter consumes file_spec; protected_spec
        # is forward-compat for runtime overlay enforcement;
        # dependency_spec lets the agent reason about parent
        # inheritance even though the file_spec accessor already
        # delegates to it transparently.
        mask: mod.mask,
        file_spec: mod.file_spec,
        package_spec: mod.package_spec,
        dependency_spec: mod.dependency_spec,
        protected_spec: mod.protected_spec,
        # Lock state — when true, no further spec edits are allowed.
        lock_spec: mod.lock_spec,
        config: mod.config,
        # Copy-path full record (or nil).
        copy_path: mod.copy_path && {
          id: mod.copy_path.id,
          name: mod.copy_path.name,
          source_path: mod.copy_path.source_path,
          destination_path: mod.copy_path.destination_path,
          recursive: mod.copy_path.recursive,
          preserve_permissions: mod.copy_path.preserve_permissions
        },
        # P8.1 — Per-service definitions. The on-node Go agent uses
        # these to write systemd unit files at attach time. Each
        # entry maps to one `system_module_services` row + its
        # outgoing dependencies for topological start order.
        services: serialize_module_services(mod),
        # Fleet-managed Unix identities + sudoers declared by this
        # module — the agent unions these across all installed
        # modules to render /etc/passwd, /etc/group, /etc/shadow,
        # /etc/gshadow, and /etc/sudoers.d/powernode-* on the node.
        users:    serialize_module_users(mod),
        groups:   serialize_module_groups(mod),
        sudoers:  serialize_module_sudoers(mod),
        data_file_size: artifact&.dig("size"),
        # erofs blob digest. The agent uses it for (a) Pull
        # verification and (b) /run/powernode/modules/<digest>
        # mountpoint pathing.
        digest: artifact&.dig("oci_digest"),
        fsverity_root_hash: artifact&.dig("fsverity_root"),
        # artifacts: full hash so the agent (or operator
        # inspecting the API) can see what's published. Useful
        # for diagnostics; the agent reads `digest` directly.
        artifacts: mod.current_version&.artifacts || {},
        puppet_modules: mod.puppet_modules.enabled.map { |p| { id: p.id, name: p.name } }
      )
    end

    # Render each ModuleService row in the shape the agent's
    # internal/lifecycle package expects. `dependencies` carries
    # the names of services that must be `Type=notify`-up before
    # this one starts; the agent topologically sorts on these.
    #
    # `dependency_edges` carries the SAME edges plus each edge's
    # KIND, which the agent needs to decide whether the rendered
    # unit gets a hard `Requires=` or a best-effort `Wants=`.
    # Emitting the kind is not cosmetic: without it every edge —
    # including one the manifest declared `softdep` — rendered as
    # a hard `Requires=` on-node (IMP-f87b5689aca2).
    #
    # Both fields ship. `dependencies` is unchanged and remains
    # the only field an agent older than dependency_edges reads,
    # so this addition cannot strand a fleet mid-rollout; a newer
    # agent prefers `dependency_edges` and falls back to
    # `dependencies` when an older server omits it.
    def serialize_module_services(mod)
      services = mod.respond_to?(:module_services) ? mod.module_services.includes(:dependencies, outgoing_dependencies: :depends_on_module_service) : []
      services.map do |svc|
        {
          name:                          svc.name,
          start_command:                 svc.start_command,
          unit_body:                     svc.unit_body,
          stop_command:                  svc.stop_command,
          restart_policy:                svc.restart_policy,
          # ModuleService maps to either a platform-allocated
          # System::ServiceUser FK (module-declared) or a
          # WELL_KNOWN_SYSTEM_USERS string (root/nobody/etc).
          # `effective_user` resolves the two paths in the model
          # so the agent always sees the same string-shaped
          # `user` field — it pairs against the platform-managed
          # /etc/passwd the agent just rendered for ServiceUser
          # rows, or against the kernel's built-in passwd entry
          # for well-known users.
          user:                          svc.effective_user,
          working_directory:             svc.working_directory,
          env:                           svc.env || {},
          exposed_ports:                 svc.exposed_ports || [],
          capabilities:                  svc.capabilities || [],
          health_endpoint:               svc.health_endpoint,
          health_method:                 svc.health_method,
          health_interval_seconds:       svc.health_interval_seconds,
          health_timeout_seconds:        svc.health_timeout_seconds,
          health_initial_delay_seconds:  svc.health_initial_delay_seconds,
          dependencies:                  svc.dependencies.map(&:name),
          dependency_edges:              serialize_service_dependency_edges(svc),
          metadata:                      svc.metadata || {}
        }
      end
    rescue StandardError => e
      ::Rails.logger.warn("[ModulesController#serialize_module_services] #{e.class}: #{e.message}")
      []
    end

    # The kind-carrying form of a service's outgoing dependency edges.
    # `kind` is one of System::ModuleServiceDependency::KINDS; the agent
    # maps it to a systemd directive (start_before/requires_health ->
    # Requires=, softdep -> Wants=).
    def serialize_service_dependency_edges(svc)
      return [] unless svc.respond_to?(:outgoing_dependencies)
      svc.outgoing_dependencies.filter_map do |edge|
        target = edge.depends_on_module_service
        next if target.nil?
        { service: target.name, kind: edge.kind }
      end
    end

    # Fleet-managed Unix users declared by this module. Includes
    # the user's primary group + any supplementary groups so the
    # agent can render /etc/passwd lines (and resolve the supp
    # group memberships when building /etc/group). Only `live`
    # users (pending/active/draining) are emitted — `removed`
    # users have already been swept from /etc/passwd by the
    # reaper and should not be rendered again.
    def serialize_module_users(mod)
      return [] unless mod.respond_to?(:declared_service_users)
      users = mod.declared_service_users
                 .where(state: %w[pending active draining])
                 .includes(:primary_group, :supplementary_groups)
      users.map do |u|
        {
          name:                 u.username,
          uid:                  u.uid,
          primary_gid:          u.primary_gid,
          primary_group:        u.primary_groupname,
          shell:                u.shell,
          home:                 u.home,
          gecos:                u.gecos,
          supplementary_groups: u.supplementary_groups.pluck(:groupname)
        }
      end
    rescue StandardError => e
      ::Rails.logger.warn("[ModulesController#serialize_module_users] #{e.class}: #{e.message}")
      []
    end

    # Groups declared by this module (whether directly via the
    # manifest's groups: block, or auto-allocated as a same-name
    # primary group for a declared user). `members` is the
    # server-rendered list of usernames whose primary OR
    # supplementary group is this group — agent doesn't need
    # cross-module visibility to build correct /etc/group lines.
    def serialize_module_groups(mod)
      return [] unless mod.respond_to?(:declared_service_groups)
      groups = mod.declared_service_groups
                  .where(state: %w[pending active draining])
      groups.map do |g|
        {
          name:    g.groupname,
          gid:     g.gid,
          members: group_members(g)
        }
      end
    rescue StandardError => e
      ::Rails.logger.warn("[ModulesController#serialize_module_groups] #{e.class}: #{e.message}")
      []
    end

    # Union of primary-group users + supplementary-membership
    # users for the given group. Scoped to live ServiceUser rows
    # so a draining-but-not-yet-removed user still appears in
    # /etc/group (matches the user being temporarily preserved
    # to avoid breaking in-flight processes).
    def group_members(group)
      primary  = ::System::ServiceUser
                   .where(primary_group_id: group.id, state: %w[pending active draining])
                   .pluck(:username)
      via_supp = ::System::ServiceUser
                   .joins(:user_group_memberships)
                   .where(state: %w[pending active draining],
                          system_service_user_group_memberships: { service_group_id: group.id })
                   .pluck(:username)
      (primary + via_supp).uniq.sort
    end

    # Per-command sudo grants owned by this module. The agent
    # writes one /etc/sudoers.d/powernode-<module>-<id> file per
    # grant; only active grants are emitted (removed grants are
    # swept off disk by the agent's sweep step).
    def serialize_module_sudoers(mod)
      return [] unless mod.respond_to?(:sudoers_grants)
      grants = mod.sudoers_grants.active.includes(:service_user)
      grants.map do |g|
        {
          id:          g.grant_id,
          user:        g.service_user&.username,
          runas_user:  g.runas_user,
          runas_group: g.runas_group,
          commands:    Array(g.commands),
          flags:       Array(g.flags)
        }
      end
    rescue StandardError => e
      ::Rails.logger.warn("[ModulesController#serialize_module_sudoers] #{e.class}: #{e.message}")
      []
    end
  end
end
