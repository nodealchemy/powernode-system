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
              modules: resolved_modules.map { |m| ::System::NodeModuleNodeApiSerializer.new(m).summary },
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
            render_success(**::System::NodeModuleNodeApiSerializer.new(@module).full)
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
              file: ::System::NodeModuleNodeApiSerializer.new(@module).file_payload(artifact),
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
        end
      end
    end
  end
end
