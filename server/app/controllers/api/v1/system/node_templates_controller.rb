# frozen_string_literal: true

module Api
  module V1
    module System
      class NodeTemplatesController < BaseController
        before_action :set_account
        before_action :set_template, only: %i[show update destroy export clone]

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
            render_error("Failed to delete template", status: :unprocessable_content)
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
          return render_error("module_ids: required", status: :unprocessable_content) if ids.empty?

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
          composer = ::System::TemplateComposerService.new(all_modules)

          render_success(
            modules: composer.serialize_modules(explicit_ids: explicit_ids),
            conflicts: composer.detect_conflicts,
            footprint: composer.footprint,
            dependency_graph: composer.dependency_graph(explicit_ids: explicit_ids),
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
              status: :unprocessable_content,
              details: { missing_modules: result.missing_modules }
            )
          else
            render_error(result.errors.first || "import failed", status: :unprocessable_content)
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
          render_error(e.message, status: :unprocessable_content)
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
            render_error(result.error, status: :unprocessable_content)
          end
        end

        private

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
