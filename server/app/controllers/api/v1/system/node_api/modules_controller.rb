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
          # Returns format-aware metadata. The selected format is
          # determined by the calling node's heartbeat-reported
          # capabilities (composefs vs squashfs). The agent's
          # internal/oci.Puller consumes the response's `file` block
          # for streaming + sha256 verify and the `oci` block for
          # cosign material.
          def download
            format, format_artifact = pick_artifact_for_node(@module)
            if format.nil? || format_artifact.nil?
              return render_error("Module has no published artifact for node format")
            end

            render_success(
              file: build_file_payload(@module, format, format_artifact),
              oci:  {
                ref:                format_artifact["oci_ref"],
                digest:             format_artifact["oci_digest"],
                fsverity_root_hash: format_artifact["fsverity_root"],
                size_bytes:         format_artifact["size"],
                format:             format
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
          # Format-aware: pulls size + checksum from the selected
          # format's artifact entry. The agent's oci.Puller consumes
          # this for streaming + sha256 verification.
          def build_file_payload(mod, format, format_artifact)
            digest = format_artifact["oci_digest"].to_s
            extension = case format
                        when "composefs" then "cfs"
                        when "squashfs"  then "sqfs"
                        else format
                        end
            {
              name: "#{mod.name}.#{extension}",
              size: format_artifact["size"].to_i,
              checksum: digest.sub(/^sha256:/, ""),
              download_url: "/api/v1/system/node_api/files/modules/#{mod.id}?format=#{format}",
              content_type: format_artifact["media_type"]
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
            # Pick the artifact format for THIS calling node based on
            # capabilities it advertised in its last heartbeat. Both
            # formats are mandatory on every published module, so
            # pick_format_for never returns nil for a publishable
            # version — but we guard with the has_data_file gate
            # upstream (serialize_module sets it false for unpublished
            # versions, so the agent skips them before reaching here).
            format, format_artifact = pick_artifact_for_node(mod)

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
              # Sized + checksummed metadata per the SELECTED format.
              data_file_size: format_artifact&.dig("size"),
              # Dual-format dispatch — agent's reconciler uses this to
              # pick MountModule (composefs) vs MountModuleSquashfs.
              # Always set; no default — caller errors loudly on
              # missing format rather than silently picking composefs.
              format: format,
              # Format-specific blob digest. For composefs that's the
              # .cfs sha256; for squashfs that's the .sqfs sha256.
              # The agent uses it for (a) Pull verification and
              # (b) /run/powernode/modules/<digest> mountpoint pathing.
              digest: format_artifact&.dig("oci_digest"),
              fsverity_root_hash: format_artifact&.dig("fsverity_root"),
              # artifacts: full hash so the agent (or any inspector) can
              # see what's available across all formats. Invaluable for
              # diagnostics when a capability mismatch surfaces.
              artifacts: mod.current_version&.artifacts || {},
              puppet_modules: mod.puppet_modules.enabled.map { |p| { id: p.id, name: p.name } }
            )
          end

          # Returns the [format, artifact_hash] pair for the calling
          # node's capabilities. Composefs preferred when node + version
          # both support it; squashfs otherwise.
          def pick_artifact_for_node(mod)
            return [nil, nil] unless mod.current_version

            node_caps = current_instance&.capabilities || {}
            mod.current_version.pick_format_for(node_caps)
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
                # ModuleService schema uses `run_as_user` (avoiding `user`
                # which conflicts with Ruby's User constant in some
                # autoload paths). Agent's Service.User struct key
                # matches "user" in JSON, so emit under that name.
                user:                          svc.run_as_user,
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
        end
      end
    end
  end
end
