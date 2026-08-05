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
      #   PATCH  /api/v1/system/node_templates/:node_template_id/modules/:id
      #   DELETE /api/v1/system/node_templates/:node_template_id/modules/:id
      #
      # The member `:id` for create/update/destroy is the NODE_MODULE id
      # (matches the MCP `system_assign_module_to_template` /
      # `update_template_module` / `unassign_module_from_template` actions,
      # which key off module_id), not the join row's own id.
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
        #
        # Runs the same TemplateComposerService analysis compose_preview shows
        # the operator, over the module set the assignment would produce.
        # Conflict detection used to run ONLY in compose_preview, so the sole
        # thing standing between an operator and a template that cannot build
        # was a disabled button in the React composer — anything reaching this
        # endpoint directly wrote straight through. Hard conflicts now 422;
        # soft ones (protected_spec overlap, which the build pipeline
        # auto-resolves) ride the success payload under `warnings`.
        #
        # The join's own attributes (priority, enabled, config,
        # recommends_override) are settable here. They used to be reachable
        # from no write API at all, which left the destructive DELETE as the
        # only way to take a module back out of a template.
        def create
          require_permission("system.templates.update")

          module_id = params[:node_module_id]
          return render_error("node_module_id: required", status: :unprocessable_content) if module_id.blank?

          node_module = @account.system_node_modules.find_by(id: module_id)
          return render_not_found("Node Module") unless node_module

          begin
            attrs = join_params
          rescue ArgumentError => e
            return render_error(e.message, status: :unprocessable_content)
          end
          # A disabled join is not expanded onto anything, so it collides with
          # nothing — same enabled-only scoping TemplateExpansionService and
          # assignment_verdict's own baseline use. #update runs the check when
          # such a join is later enabled.
          verdict = ships?(attrs) ? assignment_verdict(node_module) : nil
          return render_error(verdict.message, status: :unprocessable_content) if verdict&.blocked?

          join = ::System::TemplateModule.new(
            attrs.merge(node_template: @template, node_module: node_module)
          )
          if join.save
            payload = { template_module: serialize_join(join) }
            # Only when non-empty — a clean assignment's payload is unchanged.
            payload[:warnings] = verdict.warnings if verdict&.warnings&.any?
            render_success(**payload, status: :created)
          else
            render_validation_error(join)
          end
        end

        # PATCH /api/v1/system/node_templates/:node_template_id/modules/:id
        # Edits an existing join in place. `enabled: false` is the
        # documented-correct removal — the row survives, so
        # source_template_module_id on every derived NodeModuleAssignment
        # survives with it. DELETE nullifies that column and orphans them
        # permanently, and until this action existed it was the only reachable
        # way to take a module out of a template.
        #
        # Permission: `system.templates.update`, same as create/destroy.
        def update
          require_permission("system.templates.update")

          join = @template.template_modules.find_by(node_module_id: params[:id])
          return render_not_found("Template Module assignment") unless join

          begin
            attrs = join_params
          rescue ArgumentError => e
            return render_error(e.message, status: :unprocessable_content)
          end
          if attrs.empty?
            return render_error("nothing to update — pass at least one of priority, enabled, config, recommends_override",
                                status: :unprocessable_content)
          end

          # Only the disabled → enabled transition adds a module to what the
          # template ships, so only it can introduce a conflict. Disabling, or
          # editing priority/config at an unchanged enabled flag, changes no
          # membership.
          if attrs[:enabled] == true && !join.enabled
            verdict = assignment_verdict(join.node_module)
            return render_error(verdict.message, status: :unprocessable_content) if verdict.blocked?
          end

          if join.update(attrs)
            render_success(template_module: serialize_join(join))
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

        # Absent keys are dropped rather than nil-assigned, so a PATCH touches
        # only what the caller named. `enabled` is cast here rather than left
        # to the model because the conflict guard branches on it BEFORE the
        # write — a string "true" that AR would cast to true must not read as
        # "not literally true, skip the check".
        def join_params
          attrs = {}
          # Raises ArgumentError on a non-integer; both callers turn that into a
          # 422 rather than letting it escape as a 500. See
          # System::TemplateModule.coerce_priority! for why nil is left alone.
          attrs[:priority] = ::System::TemplateModule.coerce_priority!(params[:priority]) unless params[:priority].nil?

          config = hash_param(:config)
          attrs[:config] = config if config

          recommends = hash_param(:recommends_override)
          attrs[:recommends_override] = recommends if recommends

          enabled = ActiveModel::Type::Boolean.new.cast(params[:enabled])
          attrs[:enabled] = enabled unless enabled.nil?
          attrs
        end

        # Nested JSON objects arrive as ActionController::Parameters, which a
        # jsonb column cannot serialize.
        def hash_param(key)
          value = params[key]
          case value
          when ActionController::Parameters then value.to_unsafe_h.deep_stringify_keys
          when Hash then value.deep_stringify_keys
          end
        end

        # TemplateModule.enabled defaults to true, so an unspecified flag ships.
        def ships?(attrs)
          attrs.fetch(:enabled, true)
        end

        def assignment_verdict(node_module)
          ::System::TemplateCompositionAnalysis
            .new(@account)
            .assignment_verdict(template: @template, node_module: node_module)
        end

        def serialize_join(join)
          {
            id: join.id,
            node_template_id: join.node_template_id,
            node_module_id: join.node_module_id,
            enabled: join.enabled,
            priority: join.priority,
            config: join.config,
            recommends_override: join.recommends_override
          }
        end
      end
    end
  end
end
