# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Update a non-canonical architecture's fields. Canonical rows
      # (the seven seeded ones) are immutable — the underlying tool will
      # return an error if asked to mutate one.
      #
      # Reference: i-would-like-to-zesty-glade.md Tier 1 — T1.A.
      class ArchitectureUpdateExecutor < CrudFactory
        skill_descriptor(
          name: "architecture_update",
          description: "Update a non-canonical architecture's fields. Canonical rows are immutable and return an error.",
          category: "fleet",
          inputs: {
            architecture_id: { type: "string", required: true },
            attributes:      { type: "object", required: true,
                                description: "Allowed: name, family, apt_name, rpm_name, display_name, description, kernel_options, enabled, public" }
          },
          outputs: { architecture: :object },
          requires_approval: true
        )

        binds_to "Fleet Autonomy"

        protected

        def perform(architecture_id:, attributes:)
          crud_perform(
            resource: "architecture", operation: "update",
            payload: { architecture_id: architecture_id, attributes: attributes }
          )
        end
      end
    end
  end
end
