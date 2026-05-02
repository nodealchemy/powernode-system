# frozen_string_literal: true

module Api
  module V1
    module System
      class NodeTemplatesController < BaseController
        before_action :set_account
        before_action :set_template, only: [:show, :update, :destroy, :export]

        def index
          require_permission("system.templates.read")
          templates = @account.system_node_templates.includes(:node_platform)
          templates = apply_filters(templates)
          templates = paginate(templates)
          render_success(node_templates: serialize_collection(templates), meta: pagination_meta)
        end

        def show
          require_permission("system.templates.read")
          render_success(node_template: serialize_template(@template))
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
          conflicts
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
