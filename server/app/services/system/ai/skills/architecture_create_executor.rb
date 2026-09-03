# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Create a custom (non-canonical) architecture in the platform-wide
      # catalog. Requires system.architectures.manage.
      #
      # Use this directly only when the agent has manage permission. Agents
      # with only `propose` should use ArchitectureProposeExecutor.
      #
      # Reference: i-would-like-to-zesty-glade.md Tier 1 — T1.A.
      class ArchitectureCreateExecutor < CrudFactory
        skill_descriptor(
          name: "architecture_create",
          description: "Directly create a custom (non-canonical) architecture. Requires system.architectures.manage; surfaces for operator approval via intervention policy.",
          category: "fleet",
          inputs: {
            name:         { type: "string",  required: true },
            family:       { type: "string",  required: true },
            apt_name:     { type: "string",  required: false },
            rpm_name:     { type: "string",  required: false },
            display_name: { type: "string",  required: false },
            description:  { type: "string",  required: false },
            enabled:      { type: "boolean", required: false },
            public:       { type: "boolean", required: false }
          },
          outputs: { architecture: :object },
          requires_approval: true,
          # DECLARED, not derived (IMP-51e5c6184ae4). The operator control for
          # this action already exists as the SEEDED
          # SUPPLY_CHAIN_MANAGER_POLICIES row "system.architecture.create"
          # (FLEET_AUTONOMY_POLICIES until HIER-P2DECL moved it); the
          # "<domain>.<skill name>" default would resolve
          # "system.architecture_create" instead, a second row over the same
          # behaviour that an operator tuning the first would never touch.
          action_category: "system.architecture.create"
        )

        binds_to "Fleet Autonomy"

        protected

        def perform(name:, family:, apt_name: nil, rpm_name: nil,
                    display_name: nil, description: nil, enabled: nil, public: nil)
          payload = { name: name, family: family,
                      apt_name: apt_name, rpm_name: rpm_name,
                      display_name: display_name, description: description }
          payload[:enabled] = enabled unless enabled.nil?
          payload[:public]  = public  unless public.nil?

          crud_perform(resource: "architecture", operation: "create", payload: payload)
        end
      end
    end
  end
end
