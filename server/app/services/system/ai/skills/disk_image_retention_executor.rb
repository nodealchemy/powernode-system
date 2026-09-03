# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Disk Image Manager skill (HIER-P2F): set a NodePlatform's disk-image
      # retention count (how many publications the purge sweep keeps). Thin
      # over System::Executors::DiskImage::UpdateRetention, with the same
      # lower bound the system_set_disk_image_retention MCP verb applies; the
      # model's upper bound (NodePlatform validates 1..50) surfaces as a
      # failure rather than a raise.
      #
      # Gated on the agent's own declared row,
      # `system.disk_image_retention_update` — declared auto_approve (GC
      # config, reversible), so the row rather than the descriptor decides
      # whether this runs: an install that tightens the verb parks it.
      class DiskImageRetentionExecutor < BaseSkillExecutor
        skill_descriptor(
          name:        "disk_image_retention",
          description: "Set a NodePlatform's disk-image retention count — how many publications the purge sweep keeps before soft-deleting older artifacts (1..50); reversible GC configuration",
          category:    "fleet",
          requires_approval: true,
          action_category:   "system.disk_image_retention_update",
          blast_radius: :low,
          inputs: {
            platform_id:     { type: "string", required: true,
                               description: "System::NodePlatform.id" },
            retention_count: { type: "integer", required: true,
                               description: "Publications to keep, 1..50" }
          },
          outputs: {
            updated:                  :boolean,
            node_platform_id:         :string,
            retention_count:          :integer,
            previous_retention_count: :integer
          }
        )

        binds_to "disk_image_manager"

        protected

        # ADMISSION BEFORE THE GATE. BaseSkillExecutor#execute runs
        # #validate_inputs! ahead of #gate_action!, so account scoping and the
        # bound check happen here — an out-of-range count can only ever fail and
        # must not park an approval. The upper bound is not restated as a
        # literal: an unsaved probe runs NodePlatform's own numericality
        # validator, so this door and the write agree by construction.
        def validate_inputs!(inputs)
          super

          @platform = ::System::NodePlatform.where(account_id: @account.id).find_by(id: inputs[:platform_id])
          raise ArgumentError, "NodePlatform #{inputs[:platform_id]} not found in this account" unless @platform

          @retention_count = inputs[:retention_count].to_i
          raise ArgumentError, "retention_count must be >= 1 (got #{@retention_count})" if @retention_count < 1

          probe = ::System::NodePlatform.new(disk_image_retention_count: @retention_count)
          probe.valid?
          messages = probe.errors.full_messages_for(:disk_image_retention_count)
          return if messages.empty?

          raise ArgumentError, "retention update refused: #{messages.to_sentence}"
        end

        def perform(platform_id:, retention_count:)
          # Resolved and admitted in #validate_inputs! above, before the gate.
          platform = @platform
          count    = @retention_count
          previous = platform.disk_image_retention_count
          result = ::System::Executors::DiskImage::UpdateRetention.execute(
            { platform_id: platform.id, retention_count: count }, deferred_operation: nil
          )

          success(
            updated:                  true,
            node_platform_id:         platform.id,
            retention_count:          result.dig(:data, :retention_count),
            previous_retention_count: previous
          )
        rescue ::ActiveRecord::RecordInvalid => e
          failure("retention update refused: #{e.record.errors.full_messages.to_sentence}")
        end
      end
    end
  end
end
