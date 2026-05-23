# frozen_string_literal: true

module Api
  module V1
    module System
      module NodeApi
        # Module data endpoint for node instances
        # Provides modules assigned to the instance's node
        class ModulesController < BaseController
          before_action :set_module, only: [ :show, :download, :resource ]

          # GET /api/v1/system/node_api/modules
          # List modules assigned to this node with dependencies resolved
          def index
            modules = node_modules.enabled.includes(:category, :dependencies)
            resolved_modules = resolve_module_dependencies(modules)

            render_success(
              modules: resolved_modules.map { |m| serialize_module(m) },
              count: resolved_modules.size
            )
          end

          # GET /api/v1/system/node_api/modules/:id
          # Get specific module details
          #
          # Response shape: render_success splats the serialized fields at
          # data.* (NOT data.module.*) so the agent's manifest.FetchAndCache
          # can decode `data` directly into its Manifest struct. Wrapping
          # under `data.module` produced an empty Manifest (no top-level
          # id/name/digest), tripping writeCache's "nil or empty ID" guard
          # and starving the reconciler of any actionable data.
          def show
            render_success(**serialize_module_full(@module))
          end

          # GET /api/v1/system/node_api/modules/:id/download
          # Get module data file download info, including the OCI
          # registry coordinates when the M1 publish pipeline has
          # produced an artifact.
          #
          # Returns the erofs artifact metadata. The agent's
          # internal/oci.Puller consumes the `file` block for
          # streaming + sha256 verify and the `oci` block for cosign
          # material.
          def download
            artifact = @module.current_version&.artifact
            return render_error("Module has no published artifact") unless artifact

            render_success(
              file: build_file_payload(@module, artifact),
              oci:  {
                ref:                artifact["oci_ref"],
                digest:             artifact["oci_digest"],
                fsverity_root_hash: artifact["fsverity_root"],
                size_bytes:         artifact["size"]
              }
            )
          end

          # GET /api/v1/system/node_api/modules/:id/rsync_spec
          # Returns the platform-rendered rsync filter file as plain
          # text. The agent's commit CLI consumes this when capturing
          # an upper-layer delta — server-side rendering centralizes
          # the cross-neighbor effective_mask logic so the agent
          # doesn't have to reimplement it.
          #
          # Phase 2 of the agent stub implementation plan; currently
          # used by future commit CLI (Phase 4) but exposed in Phase
          # 2 alongside the attach/detach surface so all module-
          # lifecycle commands have a uniform metadata source.
          def rsync_spec
            render plain: @module.rsync_spec(target: current_instance),
                   content_type: "text/plain"
          end

          # GET /api/v1/system/node_api/modules/:id/:resource
          # Get specific module resource
          def resource
            resource_name = params[:resource]

            # Check if module has the requested resource
            resource_data = @module.config&.dig("resources", resource_name)

            if resource_data.blank?
              return render_not_found("ModuleResource")
            end

            render_success(
              module_id: @module.id,
              resource: resource_name,
              data: resource_data
            )
          end

          private

          def set_module
            @module = node_modules.find(params[:id])
          rescue ActiveRecord::RecordNotFound
            render_record_not_found("NodeModule")
          end

          def node_modules
            # Two pathways for "module on this node":
            #
            # 1. Base modules — explicit NodeModuleAssignment row pointing at
            #    this node. These are the subscription-variety / standalone
            #    modules the operator attached.
            # 2. Dependant children — config-variety or instance-variety
            #    modules created via NodeModuleAssignment#create_dependant!.
            #    These have parent_module_id set and node_id pointing at this
            #    node directly; no assignment row is created (the
            #    parent_module + node FK pair already scopes them).
            #
            # The agent needs to see both. Earlier the query only honored
            # path 1, so dependant children were silently absent from the
            # on-node module list.
            assigned_ids = ::System::NodeModuleAssignment
                           .where(node_id: current_node.id, enabled: true)
                           .pluck(:node_module_id)

            dependant_ids = ::System::NodeModule
                            .where(node_id: current_node.id, enabled: true)
                            .where.not(parent_module_id: nil)
                            .pluck(:id)

            ::System::NodeModule.where(id: (assigned_ids + dependant_ids).uniq)
          end

          def resolve_module_dependencies(modules)
            # Simple topological sort based on dependencies
            resolved = []
            visited = Set.new
            temp_visited = Set.new

            modules.each do |mod|
              visit_module(mod, modules, resolved, visited, temp_visited)
            end

            resolved
          end

          def visit_module(mod, available_modules, resolved, visited, temp_visited)
            return if visited.include?(mod.id)

            if temp_visited.include?(mod.id)
              # Circular dependency detected, skip but log
              Rails.logger.warn "Circular dependency detected for module #{mod.id}"
              return
            end

            temp_visited.add(mod.id)

            mod.dependencies.each do |dep|
              if available_modules.map(&:id).include?(dep.id)
                visit_module(dep, available_modules, resolved, visited, temp_visited)
              end
            end

            temp_visited.delete(mod.id)
            visited.add(mod.id)
            resolved << mod
          end

          # Combines legacy data_file metadata with M1 OCI artifact
          # metadata so the agent always has a usable file.* block.
          # Builds the `file` block of the modules/:id/download response.
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
          def serialize_module_services(mod)
            services = mod.respond_to?(:module_services) ? mod.module_services.includes(:dependencies) : []
            services.map do |svc|
              {
                name:                          svc.name,
                start_command:                 svc.start_command,
                stop_command:                  svc.stop_command,
                restart_policy:                svc.restart_policy,
                # ModuleService now references a ServiceUser FK; the
                # agent only needs the username here (it pairs against
                # the platform-managed /etc/passwd it just rendered).
                user:                          svc.service_user&.username,
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
                metadata:                      svc.metadata || {}
              }
            end
          rescue StandardError => e
            ::Rails.logger.warn("[ModulesController#serialize_module_services] #{e.class}: #{e.message}")
            []
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
    end
  end
end
