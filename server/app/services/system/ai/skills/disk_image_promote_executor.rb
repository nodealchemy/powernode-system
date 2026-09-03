# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Disk Image Manager skill (HIER-P2F, R4 of the 2026-06-28 campaign):
      # promote a verified disk-image publication to its NodePlatform's active
      # default. Thin over System::Executors::DiskImage::PromotePublication —
      # the same transaction the system_set_default_disk_image_publication MCP
      # verb and DiskImagePublicationsController run — and it takes that verb's
      # admission rule (status "published" only; a retired publication is the
      # ROLLBACK skill's business), so the three doors agree on what a promote
      # accepts.
      #
      # Gated on the agent's own declared row, `system.disk_image_publication_
      # promote` (PolicyDeclarations::DISK_IMAGE_MANAGER_POLICIES,
      # require_approval): declaring THAT spelling rather than the derived
      # "system.disk_image_promote" keeps the category from being spelled twice
      # (autonomy_category_spelling_uniqueness_spec). NOTE the row governs THIS
      # door only — system_set_default_disk_image_publication is declared
      # `mutating:`-only and the REST promote path gates on permissions, so an
      # operator tuning this row constrains the agent, not the MCP verb.
      class DiskImagePromoteExecutor < BaseSkillExecutor
        skill_descriptor(
          name:        "disk_image_promote",
          description: "Promote a published disk-image publication to its NodePlatform's active default — every instance provisioned on the platform afterwards boots from it; the previously active publication is retired in the same transaction",
          category:    "fleet",
          requires_approval: true,
          action_category:   "system.disk_image_publication_promote",
          blast_radius: :high,
          inputs: {
            publication_id: { type: "string", required: true,
                              description: "System::DiskImagePublication.id — must be in status published" }
          },
          outputs: {
            promoted:                :boolean,
            publication_id:          :string,
            node_platform_id:        :string,
            oci_ref:                 :string,
            git_sha:                 :string,
            previous_publication_id: :string
          }
        )

        binds_to "disk_image_manager"

        protected

        # ADMISSION BEFORE THE GATE. BaseSkillExecutor#execute runs
        # #validate_inputs! ahead of #gate_action! on purpose — "a call that
        # could only ever fail must not park an approval an operator then has to
        # dispose of" — so account scoping and the published-only admission rule
        # belong HERE, not in #perform. The MCP door pre-validates for the same
        # reason. An ArgumentError raised here reaches the same `failure(msg)`
        # envelope a return from #perform would have produced.
        def validate_inputs!(inputs)
          super

          @publication = ::System::DiskImagePublication
            .where(account_id: @account.id).find_by(id: inputs[:publication_id])
          unless @publication
            raise ArgumentError, "DiskImagePublication #{inputs[:publication_id]} not found in this account"
          end

          return if @publication.status == "published"

          raise ArgumentError,
                "publication #{@publication.id} is in status=#{@publication.status.inspect}; only a " \
                "published publication can be promoted to the platform default (use disk_image_rollback " \
                "to reactivate a retired one)"
        end

        def perform(publication_id:)
          # Resolved and admitted in #validate_inputs! above, before the gate.
          publication = @publication
          platform = publication.node_platform
          previous = active_publication(platform)

          ::System::Executors::DiskImage::PromotePublication.execute(
            { "publication_id" => publication.id }, deferred_operation: nil
          )
          platform.reload

          success(
            promoted:                true,
            publication_id:          publication.id,
            node_platform_id:        platform.id,
            oci_ref:                 platform.disk_image_oci_ref,
            git_sha:                 platform.disk_image_git_sha,
            previous_publication_id: previous&.id
          )
        end

        private

        # The publication whose artifact the platform currently boots from —
        # the row the promote will retire.
        def active_publication(platform)
          return nil if platform.disk_image_file_object_id.blank?

          platform.disk_image_publications
                  .where(file_object_id: platform.disk_image_file_object_id, status: "published")
                  .first
        end
      end
    end
  end
end
