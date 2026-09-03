# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Disk Image Manager skill (HIER-P2F): roll a NodePlatform's active disk
      # image back to a prior publication. Thin over
      # System::Executors::DiskImage::RollbackPublication with the SAME target
      # selection and pre-checks the system_revert_disk_image MCP verb performs
      # (SystemFleetTool#revert_disk_image): an explicit publication_id, else
      # the newest retired publication, else the newest published one that is
      # not current; purged rows and rows with no stored artifact are refused
      # here so an approval is never parked for a rollback that can only fail.
      #
      # Gated on the agent's own declared row,
      # `system.disk_image_publication_rollback` (require_approval — the
      # rollback IS a fleet event; see DISK_IMAGE_MANAGER_AGENT.md).
      class DiskImageRollbackExecutor < BaseSkillExecutor
        skill_descriptor(
          name:        "disk_image_rollback",
          description: "Roll a NodePlatform's active disk image back to a prior publication — an explicit one, else the newest retired publication, else the newest published one that is not current; restores a retired artifact and retires the previously active publication in one transaction",
          category:    "fleet",
          requires_approval: true,
          action_category:   "system.disk_image_publication_rollback",
          blast_radius: :high,
          inputs: {
            platform_id:    { type: "string", required: true,
                              description: "System::NodePlatform.id whose active image is rolled back" },
            publication_id: { type: "string", required: false,
                              description: "Target System::DiskImagePublication.id; omitted = auto-select the prior publication" }
          },
          outputs: {
            reverted:                 :boolean,
            node_platform_id:         :string,
            activated_publication_id: :string,
            previous_publication_id:  :string,
            previous_file_object_id:  :string
          }
        )

        binds_to "disk_image_manager"

        protected

        # ADMISSION BEFORE THE GATE. BaseSkillExecutor#execute runs
        # #validate_inputs! ahead of #gate_action!, and every refusal below is
        # decidable from the inputs alone — so resolving the platform, selecting
        # the target and rejecting a purged or artifact-less one all happen here
        # rather than in #perform. Otherwise an operator is asked to approve a
        # rollback that can only fail on replay; the REST door pre-checks the
        # same two conditions before calling Ai::AutonomyGate for that reason.
        def validate_inputs!(inputs)
          super

          @platform = ::System::NodePlatform.where(account_id: @account.id).find_by(id: inputs[:platform_id])
          raise ArgumentError, "NodePlatform #{inputs[:platform_id]} not found in this account" unless @platform

          publication_id = inputs[:publication_id]
          @target = if publication_id.present?
                      @platform.disk_image_publications.find_by(id: publication_id)
          else
                      previous_publication(@platform)
          end

          unless @target
            raise ArgumentError,
                  publication_id.present? ?
                    "DiskImagePublication #{publication_id} not found for platform #{@platform.id}" :
                    "No prior publication available to revert to for platform #{@platform.id}"
          end

          if @target.purged?
            raise ArgumentError,
                  "Cannot revert to a purged publication #{@target.id} — its artifact was hard-deleted past the " \
                  "grace window. Re-trigger CI to rebuild."
          end

          return if @target.file_object_id.present?

          raise ArgumentError, "Target publication #{@target.id} has no stored artifact — was it ever published?"
        end

        def perform(platform_id:, publication_id: nil)
          # Resolved and admitted in #validate_inputs! above, before the gate.
          platform = @platform
          target   = @target
          previous = active_publication(platform)
          result = ::System::Executors::DiskImage::RollbackPublication.execute(
            { target_publication_id: target.id, platform_id: platform.id },
            deferred_operation: nil
          )

          success(
            reverted:                 true,
            node_platform_id:         platform.id,
            activated_publication_id: target.id,
            previous_publication_id:  previous&.id,
            previous_file_object_id:  result.dig(:data, :previous_file_object_id)
          )
        end

        private

        # Newest "prior" publication for auto-revert: prefer the most recent
        # retired publication; otherwise the most recent published one that
        # isn't the currently-active image. Mirrors
        # SystemFleetTool#previous_disk_image_publication so the skill door
        # and the MCP door pick the same target.
        def previous_publication(platform)
          retired = platform.disk_image_publications
                            .where(status: "retired")
                            .order(created_at: :desc)
                            .first
          return retired if retired

          platform.disk_image_publications
                  .where(status: "published")
                  .where.not(file_object_id: platform.disk_image_file_object_id)
                  .order(created_at: :desc)
                  .first
        end

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
