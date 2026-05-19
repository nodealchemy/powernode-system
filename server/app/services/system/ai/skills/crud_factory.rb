# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Shared routing parent for CRUD-style skill executors. Eliminates
      # duplication across thin executors that all do the same thing:
      # "look up an MCP tool, build params with an action name, call it,
      # wrap the result in success/failure".
      #
      # Subclasses declare their `skill_descriptor`, `binds_to`, and a
      # `perform(...)` method that calls `crud_perform(resource:, operation:, payload:)`.
      # The factory looks up `(resource, operation)` in `ROUTES` and dispatches
      # to the right `Ai::Tools::*Tool` action.
      #
      # NOTE on plan deviation: the original overhaul plan called for ONE
      # `CrudFactory` executor with three `Ai::Skill` rows pointing at it
      # via `metadata.executor_args = { resource:, operation: }`. The
      # `executor_args` merge mechanism doesn't exist in `Ai::ConciergeRouter`
      # or `Ai::Provisioning::SkillCompositionRunner` — both invoke
      # `executor.execute(**inputs)` directly. Adding executor_args is
      # invocation-surface infrastructure work that's out of scope for this
      # overhaul. The implementation here preserves the plan's intent
      # (eliminate duplication) within existing infrastructure: thin
      # subclasses inherit the routing logic, each is ~30 lines instead of
      # the original ~50.
      class CrudFactory < BaseSkillExecutor
        # Map (resource, operation) → (tool class, action name). Adding a
        # new CRUD route here lets a new subclass land without touching
        # the executor code paths.
        ROUTES = {
          [ "architecture", "create" ] => [ ::Ai::Tools::SystemArchitectureCatalogTool, "system_create_architecture" ],
          [ "architecture", "update" ] => [ ::Ai::Tools::SystemArchitectureCatalogTool, "system_update_architecture" ],
          [ "architecture", "delete" ] => [ ::Ai::Tools::SystemArchitectureCatalogTool, "system_delete_architecture" ]
        }.freeze

        protected

        # Subclass `perform(...)` methods call this to dispatch to the
        # registered MCP tool action. Returns the canonical
        # success/failure shape from BaseSkillExecutor.
        def crud_perform(resource:, operation:, payload:)
          route = ROUTES[[ resource.to_s, operation.to_s ]]
          return failure("unsupported CrudFactory route: #{resource}/#{operation}") if route.nil?

          tool_class, action = route
          result = tool(tool_class).execute(params: payload.merge(action: action))
          result[:success] ? success(result[:data]) : failure(result[:error])
        end
      end
    end
  end
end
