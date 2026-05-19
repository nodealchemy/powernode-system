# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Delete a non-canonical architecture. Fails if any NodePlatform
      # still references it (restrict_with_error dependency). Canonical
      # rows can't be deleted.
      #
      # Reference: i-would-like-to-zesty-glade.md Tier 1 — T1.A.
      class ArchitectureDeleteExecutor < CrudFactory
        skill_descriptor(
          name: "architecture_delete",
          description: "Delete a non-canonical architecture. Fails if any NodePlatform still references it. Canonical rows are immutable and return an error.",
          category: "fleet",
          inputs: {
            architecture_id: { type: "string", required: true }
          },
          outputs: {
            deleted: :boolean,
            architecture_id: :string
          },
          requires_approval: true
        )

        binds_to "Fleet Autonomy"

        protected

        def perform(architecture_id:)
          crud_perform(
            resource: "architecture", operation: "delete",
            payload: { architecture_id: architecture_id }
          )
        end
      end
    end
  end
end
