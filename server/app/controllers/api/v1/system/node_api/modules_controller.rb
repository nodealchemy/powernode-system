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
          def show
            render_success(module: serialize_module_full(@module))
          end

          # GET /api/v1/system/node_api/modules/:id/download
          # Get module data file download info, including the OCI
          # registry coordinates when the M1 publish pipeline has
          # produced an artifact.
          #
          # Phase 1 extension: oci block exposes the data the agent's
          # internal/oci.Puller needs for streaming + sha256 verify
          # (oci_ref, digest, architecture, fsverity_root_hash). Falls
          # back to download_url-only when no artifact has been
          # published yet (back-compat with pre-M1 modules).
          def download
            unless @module.data_file_name.present?
              return render_error("Module has no data file")
            end

            payload = {
              file: {
                name: @module.data_file_name,
                size: @module.data_file_size,
                checksum: @module.data_checksum,
                download_url: module_download_url(@module)
              }
            }
            if (artifact = preferred_artifact(@module))
              payload[:oci] = {
                ref: artifact.oci_ref,
                digest: artifact.oci_digest,
                architecture: artifact.architecture,
                fsverity_root_hash: artifact.fsverity_root_hash,
                size_bytes: artifact.size_bytes,
                cosign_bundle_url: artifact.cosign_bundle.present? ? "/api/v1/system/node_api/files/modules/#{@module.id}/cosign-bundle" : nil
              }.compact
            end
            render_success(payload)
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
          rescue NoMethodError => e
            # NodeModule#rsync_spec target: signature lands in the
            # commit-CLI prep work; until then, fall back to the
            # spec-only render if the model doesn't have the helper.
            Rails.logger.warn("[ModulesController#rsync_spec] falling back: #{e.message}")
            render plain: render_rsync_fallback(@module),
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

          def module_download_url(mod)
            # Generate URL for file download
            "/api/v1/system/node_api/files/modules/#{mod.id}/#{mod.data_file_name}"
          end

          # render_rsync_fallback synthesizes a minimal rsync filter
          # file from the module's mask + file_spec when the model's
          # full rsync_spec helper isn't present (transitional —
          # remove once the helper lands platform-wide).
          def render_rsync_fallback(mod)
            lines = []
            Array(mod.mask).each       { |p| lines << "- #{p}" }
            Array(mod.file_spec).each  { |p| lines << "+ #{p}" }
            lines << "- *"
            lines.join("\n") + "\n"
          end

          # preferred_artifact picks the ModuleArtifact whose architecture
          # matches the calling instance, falling back to any artifact
          # if no arch-specific match exists. Returns nil when the
          # module has no current_version or no artifacts yet.
          def preferred_artifact(mod)
            version = mod.current_version
            return nil unless version

            artifacts = version.module_artifacts
            return nil if artifacts.blank?

            arch = current_instance.architecture.presence
            (arch && artifacts.find { |a| a.architecture == arch }) || artifacts.first
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
              has_data_file: mod.data_file_name.present?,
              current_version: mod.current_version_number,
              dependencies: mod.dependencies.map(&:id)
            }
          end

          def serialize_module_full(mod)
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
              # Legacy `.info` sidecar — key=value lines in the order the
              # legacy on-node tooling expected. Kept for parity until the
              # Go agent fully migrates to the JSON shape above.
              info: mod.info,
              data_file_name: mod.data_file_name,
              data_file_size: mod.data_file_size,
              data_checksum: mod.data_checksum,
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
                user:                          svc.user,
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
