# frozen_string_literal: true

module Api
  module V1
    module System
      # Operator-facing toggle for per-(node, module) enabled state.
      #
      # Legacy parity: powernode-server's node_module_subscription join allowed
      # operators to disable a module on specific nodes without detaching it
      # globally. The current schema preserves that capability via the
      # `System::NodeModuleAssignment#enabled` column + scopes — this
      # controller exposes the toggle.
      #
      # Reading the assignment is via the parent NodeModule's
      # /api/v1/system/node_modules/:id (which embeds assignments). This
      # controller's only concern is the enable/disable transition.
      #
      # Permission: `system.modules.update` (same as parent module mutation).
      #
      # Reference: comprehensive stabilization sweep P2.2.
      class NodeModuleAssignmentsController < BaseController
        before_action :set_account
        before_action :set_assignment

        # GET /api/v1/system/node_module_assignments/:id
        # Read-only fetch of a single assignment. Useful when the operator UI
        # wants to display assignment-level state (enabled, priority, config)
        # without re-fetching the parent NodeModule.
        def show
          require_permission("system.modules.read")
          render_success(node_module_assignment: serialize_assignment(@assignment))
        end

        # POST /api/v1/system/node_module_assignments/:id/enable
        # Sets enabled=true. Idempotent: enabling an already-enabled
        # assignment is a no-op success. Triggers neighbor recomputation
        # the next time the parent module's effective_mask is computed.
        def enable
          require_permission("system.modules.update")

          if @assignment.update(enabled: true)
            render_success(
              node_module_assignment: serialize_assignment(@assignment.reload),
              message: "Assignment enabled"
            )
          else
            render_validation_error(@assignment)
          end
        end

        # POST /api/v1/system/node_module_assignments/:id/disable
        # Sets enabled=false. Idempotent. The module remains attached to the
        # node (the assignment row is preserved) but won't participate in
        # neighbor union mounts or rsync_spec generation. Re-enable to
        # restore without losing priority/config.
        def disable
          require_permission("system.modules.update")

          if @assignment.update(enabled: false)
            render_success(
              node_module_assignment: serialize_assignment(@assignment.reload),
              message: "Assignment disabled"
            )
          else
            render_validation_error(@assignment)
          end
        end

        private

        def set_assignment
          # Scope through the account's nodes to enforce per-account isolation —
          # never use NodeModuleAssignment.find directly.
          @assignment = ::System::NodeModuleAssignment
            .joins(:node)
            .where(system_nodes: { account_id: @account.id })
            .find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render_not_found("Node Module Assignment")
        end

        def serialize_assignment(assignment)
          {
            id: assignment.id,
            node_id: assignment.node_id,
            node_module_id: assignment.node_module_id,
            enabled: assignment.enabled,
            priority: assignment.priority,
            config: assignment.config,
            created_at: assignment.created_at,
            updated_at: assignment.updated_at
          }
        end
      end
    end
  end
end
