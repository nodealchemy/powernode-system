# frozen_string_literal: true

module Api
  module V1
    module System
      # REST surface for the TemplateModule join — the modules attached to a
      # NodeTemplate. Nested under node_templates (mirrors ProviderRegions
      # under providers). Replaces the former NodeTemplatesController#modules /
      # #assign_module member actions, which lived on the parent controller and
      # pushed it over the 300-line guideline.
      #
      # URLs (unchanged from the old member routes):
      #   GET    /api/v1/system/node_templates/:node_template_id/modules
      #   POST   /api/v1/system/node_templates/:node_template_id/modules
      #   DELETE /api/v1/system/node_templates/:node_template_id/modules/:id
      #
      # The member `:id` for create/destroy is the NODE_MODULE id (matches the
      # MCP `system_assign_module_to_template` / `unassign_module_from_template`
      # actions, which key off module_id), not the join row's own id.
      class TemplateModulesController < BaseController
        before_action :set_account
        before_action :set_template

        # GET /api/v1/system/node_templates/:node_template_id/modules
        # Returns the NodeModule rows assigned to this template, ordered by the
        # join row's priority (matches the operator's compose order). The
        # Visual Template Composer's TemplateDetailModal hits this on open.
        # Keeps the `node_modules` response key the frontend already reads.
        def index
          require_permission("system.templates.read")
          mods = @template.template_modules
                          .includes(node_module: %i[category current_version node_platform])
                          .order(:priority)
                          .map(&:node_module)
                          .compact
          render_success(node_modules: mods.map { |m| ::System::NodeModuleSerializer.new(m).as_json })
        end

        # POST /api/v1/system/node_templates/:node_template_id/modules
        # Attaches a NodeModule to this template by creating a TemplateModule
        # join row. Body: { node_module_id: "..." }. Mirrors the MCP
        # `system_assign_module_to_template` action (SystemFleetTool) so the
        # operator UI (Visual Template Composer's SaveTemplateModal) has a REST
        # path — previously TemplateModule creation was MCP-only.
        #
        # Permission: `system.templates.update` (same as mutating the template
        # itself — attaching a module changes the template's composition).
        # The module is resolved within the current account, so cross-account
        # references 404 rather than leak existence.
        def create
          require_permission("system.templates.update")

          module_id = params[:node_module_id]
          return render_error("node_module_id: required", status: :unprocessable_content) if module_id.blank?

          node_module = @account.system_node_modules.find_by(id: module_id)
          return render_not_found("Node Module") unless node_module

          join = ::System::TemplateModule.new(node_template: @template, node_module: node_module)
          if join.save
            render_success(
              template_module: {
                id: join.id,
                node_template_id: join.node_template_id,
                node_module_id: join.node_module_id,
                enabled: join.enabled,
                priority: join.priority
              },
              status: :created
            )
          else
            render_validation_error(join)
          end
        end

        # DELETE /api/v1/system/node_templates/:node_template_id/modules/:id
        # Detaches a NodeModule from this template by destroying its
        # TemplateModule join row. The member `:id` is the NODE_MODULE id
        # (matches create's use of node_module_id and the MCP
        # `unassign_module_from_template` action). Idempotent-shaped: a missing
        # assignment 404s rather than erroring.
        #
        # Permission: `system.templates.update` (same as attaching — both
        # mutate the template's composition).
        def destroy
          require_permission("system.templates.update")

          join = @template.template_modules.find_by(node_module_id: params[:id])
          return render_not_found("Template Module assignment") unless join

          join.destroy
          render_success(message: "Module removed from template")
        end

        private

        def set_template
          @template = @account.system_node_templates.find(params[:node_template_id])
        rescue ActiveRecord::RecordNotFound
          render_not_found("Node Template")
        end
      end
    end
  end
end
