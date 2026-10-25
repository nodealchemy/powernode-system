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
          # NOT gated here: this executor reaches system_delete_architecture
          # through CrudFactory, and that tool action is itself gated
          # (Ai::Executors::DeferredToolCall, category system.architecture.delete,
          # c13-2 batch E-D). A gate on both parked a second approval on the
          # replay and the row survived. The tool is the single gate; its
          # deny overlay and permission check run on every path.
          requires_approval: false,
          # DECLARED, not derived — see ArchitectureCreateExecutor
          # (IMP-51e5c6184ae4): the seeded row is "system.architecture.delete",
          # the same category the tool's declaration parks under.
          action_category: "system.architecture.delete"
        )

        binds_to "supply_chain_manager"

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
