# frozen_string_literal: true

module Api
  module V1
    module System
      class NodeTemplatesController < BaseController
        before_action :set_account
        before_action :set_template, only: %i[show update destroy export modules]

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

          modules = @account.system_node_modules
                       .where(id: ids)
                       .includes(:current_version, :category, :node_platform)
          return render_error("no matching modules", status: :not_found) if modules.empty?

          render_success(
            modules: modules.map { |m| compose_serialize_module(m) },
            conflicts: compose_detect_conflicts(modules),
            footprint: compose_footprint(modules),
            dependency_graph: compose_dependency_graph(modules)
          )
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

        def compose_serialize_module(m)
          {
            id: m.id,
            name: m.name,
            variety: m.variety,
            priority: m.priority,
            effective_priority: m.respond_to?(:effective_priority) ? m.effective_priority : m.priority,
            category_id: m.category_id,
            current_version: m.current_version&.then do |v|
              { id: v.id, version_number: v.version_number, oci_digest: v.try(:oci_digest) }
            end
          }
        end

        def compose_detect_conflicts(modules)
          conflicts = []

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

        def compose_dependency_graph(modules)
          ids = modules.map(&:id).to_set
          {
            nodes: modules.map { |m| { id: m.id, name: m.name, variety: m.variety } },
            edges: modules.filter_map do |m|
              next unless m.respond_to?(:parent_module_id) && m.parent_module_id && ids.include?(m.parent_module_id)
              { source: m.parent_module_id, target: m.id, type: "depends_on" }
            end
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
