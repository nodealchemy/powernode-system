# frozen_string_literal: true

module Api
  module V1
    module System
      class NodeTemplatesController < BaseController
        before_action :set_account
        before_action :set_template, only: %i[show update destroy export modules clone]

        def index
          require_permission("system.templates.read")
          templates = @account.system_node_templates.includes(
            :node_platform,
            template_modules: { node_module: :category }
          )
          templates = apply_filters(templates)
          templates = paginate(templates)
          render_success(node_templates: serialize_collection(templates), meta: pagination_meta)
        end

        def show
          require_permission("system.templates.read")
          render_success(node_template: serialize_template(@template))
        end

        # GET /api/v1/system/node_templates/:id/modules
        # Returns the NodeModule rows assigned to this template, ordered by
        # the join row's priority (matches operator's compose order).
        # Frontend's TemplateDetailModal hits this on open.
        def modules
          require_permission("system.templates.read")
          mods = @template.template_modules
                          .includes(node_module: %i[category current_version node_platform])
                          .order(:priority)
                          .map(&:node_module)
                          .compact
          render_success(node_modules: mods.map { |m| ::System::NodeModuleSerializer.new(m).as_json })
        end

        def create
          require_permission("system.templates.create")
          template = @account.system_node_templates.build(template_params)

          if template.save
            render_success(node_template: serialize_template(template), status: :created)
          else
            render_validation_error(template)
          end
        end

        def update
          require_permission("system.templates.update")

          if @template.update(template_params)
            render_success(node_template: serialize_template(@template))
          else
            render_validation_error(@template)
          end
        end

        def destroy
          require_permission("system.templates.delete")

          if @template.destroy
            render_success(message: "Template deleted successfully")
          else
            render_error("Failed to delete template", status: :unprocessable_entity)
          end
        end

        # POST /api/v1/system/node_templates/compose_preview
        # Operator-driven preview for the visual Template Composer (M-FE-1).
        # Takes a list of module_ids and returns the projected composition,
        # conflicts, and footprint estimate without persisting any record.
        # Reuses the same conflict detection logic as ModuleComposeExecutor.
        def compose_preview
          require_permission("system.templates.update")

          ids = Array(params[:module_ids])
          return render_error("module_ids: required", status: :unprocessable_entity) if ids.empty?

          requested = @account.system_node_modules
                              .where(id: ids)
                              .includes(:current_version, :category, :node_platform,
                                        :module_dependencies, :dependencies, :package_module_link)
          return render_error("no matching modules", status: :not_found) if requested.empty?

          # Walk ModuleDependency edges to compute the full closure. This is
          # the new behavior: the response includes BOTH the operator's
          # explicit picks AND the transitive requires/recommends pulled
          # in by closure expansion.
          resolver = ::System::DependencyResolutionService.new(
            @account.system_node_modules.enabled
              .includes(:module_dependencies, :dependencies, :package_module_link).to_a
          )
          resolution = resolver.resolve(requested.to_a)

          all_modules = resolution.modules
          explicit_ids = requested.map(&:id).to_set

          render_success(
            modules: all_modules.map { |m| compose_serialize_module(m, auto_resolved: !explicit_ids.include?(m.id)) },
            conflicts: compose_detect_conflicts(all_modules),
            footprint: compose_footprint(all_modules),
            dependency_graph: compose_dependency_graph(all_modules, explicit_ids: explicit_ids),
            warnings: Array(resolution.warnings).map { |w| w.is_a?(Hash) ? w[:message] : w.to_s },
            errors:   Array(resolution.errors).map  { |e| e.is_a?(Hash) ? e[:message] : e.to_s }
          )
        end

        # POST /api/v1/system/node_templates/import
        # Body: { bundle: <TemplateExporter JSON>, name?: <override> }
        # Symmetric to /api/v1/system/node_templates/:id/export. Refuses
        # if any referenced module is missing in the target account.
        def import
          require_permission("system.templates.create")

          bundle_param = params[:bundle]
          return render_error("bundle param required", status: :bad_request) if bundle_param.blank?

          bundle =
            if bundle_param.is_a?(ActionController::Parameters)
              bundle_param.to_unsafe_h.deep_stringify_keys
            elsif bundle_param.is_a?(Hash)
              bundle_param.deep_stringify_keys
            elsif bundle_param.is_a?(String)
              begin
                JSON.parse(bundle_param)
              rescue JSON::ParserError => e
                return render_error("bundle JSON parse failed: #{e.message}", status: :bad_request)
              end
            else
              return render_error("bundle must be a Hash or JSON string", status: :bad_request)
            end

          result = ::System::TemplateImporter.new(@account).import!(
            bundle: bundle,
            new_name: params[:name].presence
          )

          if result.ok?
            render_success(
              node_template: serialize_template(result.template),
              template_modules_count: result.template_modules_count,
              status: :created
            )
          elsif result.missing_modules.any?
            render_error(
              result.errors.first || "missing modules",
              status: :unprocessable_entity,
              details: { missing_modules: result.missing_modules }
            )
          else
            render_error(result.errors.first || "import failed", status: :unprocessable_entity)
          end
        end

        # POST /api/v1/system/node_templates/:id/clone
        # Deep-clones a template + its TemplateModule rows (priorities,
        # enabled flags, per-module config, recommends_override all
        # preserved). Body: { name?: "..." } — defaults to "<source>-copy".
        def clone
          require_permission("system.templates.create")

          new_template = ::System::TemplateCloneService.new(@template).clone!(
            new_name: params[:name].presence
          )
          render_success(node_template: serialize_template(new_template), status: :created)
        rescue ::System::TemplateCloneService::CloneError => e
          render_error(e.message, status: :unprocessable_entity)
        end

        # GET /api/v1/system/node_templates/:id/export
        # Streams the template, its platform reference, and all module
        # assignments as a downloadable JSON bundle. Read permission only —
        # the caller cannot mutate state, just observes it.
        def export
          require_permission("system.templates.read")

          result = ::System::TemplateExporter.export(template: @template)
          if result.success?
            send_data(
              JSON.pretty_generate(result.data[:bundle]),
              type: "application/json",
              filename: result.data[:filename],
              disposition: "attachment"
            )
          else
            render_error(result.error, status: :unprocessable_entity)
          end
        end

        private

        # === Compose-preview helpers (M-FE-1) ===

        def compose_serialize_module(m, auto_resolved: false)
          link = m.respond_to?(:package_module_link) ? m.package_module_link : nil
          {
            id: m.id,
            name: m.name,
            variety: m.variety,
            priority: m.priority,
            effective_priority: m.respond_to?(:effective_priority) ? m.effective_priority : m.priority,
            category_id: m.category_id,
            auto_resolved: auto_resolved,
            auto_generated: m.respond_to?(:auto_generated) ? m.auto_generated : false,
            package_source: link.present? ? { repository_id: link.package_repository_id,
                                              package_name: link.package_name,
                                              package_version: link.package_version,
                                              architecture: link.architecture } : nil,
            current_version: m.current_version&.then do |v|
              { id: v.id, version_number: v.version_number, oci_digest: v.try(:oci_digest) }
            end
          }
        end

        def compose_detect_conflicts(modules)
          conflicts = []
          module_ids = modules.map(&:id).to_set

          # Hard conflict: explicit ModuleDependency rows of type "conflicts"
          # where both modules ended up in the closure. This catches the
          # apt/rpm `Conflicts:` semantics for package-driven modules.
          modules.each do |m|
            next unless m.respond_to?(:module_dependencies)

            m.module_dependencies.conflicts.each do |conflict_dep|
              other_id = conflict_dep.dependency_id
              next unless module_ids.include?(other_id)

              conflicts << {
                kind: "module_dependency_conflict",
                severity: "error",
                source_id: m.id,
                source_name: m.name,
                target_id: other_id,
                target_name: conflict_dep.dependency&.name,
                detail: "#{m.name} declares a Conflicts: relation against #{conflict_dep.dependency&.name}"
              }
            end
          end

          # Hard conflict: two instance-variety modules in the same category.
          # Only one instance can ship per category; the second would silently
          # collide at build time.
          modules.group_by(&:category_id).each do |cat_id, ms|
            instance_variety = ms.select { |m| m.variety == "instance" }
            if instance_variety.size > 1
              conflicts << {
                kind: "instance_variety_collision",
                category_id: cat_id,
                module_ids: instance_variety.map(&:id),
                detail: "Only one instance-variety module per category is allowed"
              }
            end
          end

          # Soft conflict: another module's file_spec covers paths this
          # module has claimed via protected_spec. Build pipeline will
          # auto-resolve (the other module's blob excludes the path), but
          # the operator probably wants to know — that's the whole point
          # of protected_spec being visible at composition time.
          decoded = modules.each_with_object({}) do |m, acc|
            acc[m.id] = {
              module:         m,
              file_spec:      decode_b64_array(Array(m.file_spec)),
              protected_spec: decode_b64_array(Array(m.protected_spec))
            }
          end

          decoded.each do |claimer_id, claimer|
            next if claimer[:protected_spec].empty?
            decoded.each do |other_id, other|
              next if other_id == claimer_id
              next if other[:file_spec].empty?

              overlapping = claimer[:protected_spec].each_with_object([]) do |claim, acc|
                if other[:file_spec].any? { |fs| compose_paths_overlap?(claim, fs) }
                  acc << claim
                end
              end
              next if overlapping.empty?

              conflicts << {
                kind: "protected_spec_overlap",
                severity: "warning",
                claimer_id:   claimer[:module].id,
                claimer_name: claimer[:module].name,
                other_id:     other[:module].id,
                other_name:   other[:module].name,
                paths: overlapping,
                detail: "#{other[:module].name}'s file_spec covers paths claimed by " \
                        "#{claimer[:module].name}'s protected_spec. Build pipeline will " \
                        "exclude them from #{other[:module].name}'s blob; only " \
                        "#{claimer[:module].name} will ship them."
              }
            end
          end

          conflicts
        end

        # Decodes a NodeModule jsonb-array spec column to plain glob lines.
        def decode_b64_array(arr)
          arr.map { |entry| ::Base64.decode64(entry.to_s) }
        end

        # Cheap path-prefix overlap check. Strips trailing `/*` or `/**`
        # segments and tests prefix containment in either direction. Not
        # a full rsync-glob matcher — that's what the build pipeline runs;
        # we just need a usefully-loud preview signal.
        def compose_paths_overlap?(a, b)
          ax = a.to_s.sub(%r{/\*\*\z}, "").sub(%r{/\*\z}, "")
          bx = b.to_s.sub(%r{/\*\*\z}, "").sub(%r{/\*\z}, "")
          return true if ax == bx
          return true if a.to_s == b.to_s
          ax.start_with?("#{bx}/") || bx.start_with?("#{ax}/")
        end

        def compose_footprint(modules)
          {
            module_count: modules.size,
            estimated_package_count: modules.sum { |m| Array(m.respond_to?(:package_spec) ? m.package_spec : []).size },
            architectures: modules.map { |m| m.node_platform&.node_architecture&.name }.compact.uniq
          }
        end

        def compose_dependency_graph(modules, explicit_ids: Set.new)
          ids = modules.map(&:id).to_set

          # Layer 1: parent_module hierarchy (config/instance dependant children)
          parent_edges = modules.filter_map do |m|
            next unless m.respond_to?(:parent_module_id) && m.parent_module_id && ids.include?(m.parent_module_id)

            { source: m.parent_module_id, target: m.id, type: "depends_on" }
          end

          # Layer 2: ModuleDependency edges (requires/recommends from the new
          # package-driven materializer + any operator-authored dependencies).
          # Only include edges where BOTH endpoints are in the resolved closure.
          dep_edges = []
          modules.each do |m|
            next unless m.respond_to?(:module_dependencies)

            m.module_dependencies.each do |md|
              next unless ids.include?(md.dependency_id)

              dep_edges << {
                source: m.id,
                target: md.dependency_id,
                type:   md.dependency_type,        # "requires" | "recommends" | "conflicts" | "provides"
                required: md.required?,
                version_constraint: md.version_constraint
              }
            end
          end

          {
            nodes: modules.map do |m|
              {
                id: m.id,
                name: m.name,
                variety: m.variety,
                explicit: explicit_ids.include?(m.id),
                auto_resolved: !explicit_ids.include?(m.id)
              }
            end,
            edges: parent_edges + dep_edges
          }
        end

        def set_template
          @template = @account.system_node_templates.find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render_not_found("Node Template")
        end

        def template_params
          params.require(:node_template).permit(
            :name, :description, :enabled, :public, :node_platform_id, :admin_user,
            config: {}
          )
        end

        def apply_filters(scope)
          scope = scope.enabled if params[:enabled] == "true"
          scope = scope.disabled if params[:enabled] == "false"
          scope = scope.public_access if params[:public] == "true"
          scope = scope.where(node_platform_id: params[:platform_id]) if params[:platform_id].present?
          scope.ordered
        end

        def serialize_template(template)
          ::System::NodeTemplateSerializer.new(template).as_json
        end

        def serialize_collection(templates)
          templates.map { |t| serialize_template(t) }
        end
      end
    end
  end
end
