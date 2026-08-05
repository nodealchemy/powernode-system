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

          # The closure walk, conflict detection, footprint and graph all live
          # in TemplateCompositionAnalysis so this response, the
          # system_compose_preview_template MCP action, and the assignment
          # write paths cannot drift apart. The payload includes BOTH the
          # operator's explicit picks AND the transitive requires/recommends
          # pulled in by closure expansion.
          analysis = ::System::TemplateCompositionAnalysis.new(@account)
          requested = analysis.modules_for(ids)
          return render_error("no matching modules", status: :not_found) if requested.empty?

          render_success(**analysis.preview_for(requested))
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
            payload = {
              node_template: serialize_template(result.template),
              template_modules_count: result.template_modules_count
            }
            # An import materializes a whole template's joins outside the delta
            # guard the assignment paths run, so a bundle that composes badly
            # lands as permanent baseline. TemplateImporter reports rather than
            # refusing; dropping the report here would put the signal in the
            # log and nowhere the caller can see it.
            #
            # `composition_report`, NOT the assign path's `warnings` key: this
            # surface reports blocking verdicts it does not enforce, and naming
            # them "warnings" made them indistinguishable from the advisory
            # conflicts the assign path puts under that key (IMP-493db0e5c398).
            # Each entry states its own severity. Absent when empty, so a clean
            # import's payload is unchanged.
            payload[:composition_report] = result.composition_report if result.composition_report.present?
            render_success(**payload, status: :created)
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

          service = ::System::TemplateCloneService.new(@template)
          new_template = service.clone!(new_name: params[:name].presence)

          payload = { node_template: serialize_template(new_template) }
          # A clone copies the source's joins wholesale, so a composition
          # conflict travels with it — and since the assignment guard is a
          # DELTA, what a clone lands becomes baseline that later assignments
          # must treat as acceptable. The service reports rather than refusing,
          # so the report has to leave the process here.
          #
          # `composition_report`, NOT the assign path's `warnings` key: this
          # surface reports blocking verdicts it does not enforce, and naming
          # them "warnings" made them indistinguishable from the advisory
          # conflicts the assign path puts under that key (IMP-493db0e5c398).
          # Each entry states its own severity, and carries the structured
          # detail the old `composition_conflicts` key held. Absent when empty,
          # so a clean clone's payload is unchanged.
          payload[:composition_report] = service.composition_report if service.composition_report.present?

          render_success(**payload, status: :created)
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
