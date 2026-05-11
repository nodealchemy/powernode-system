# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Delete a non-canonical architecture. Fails if any NodePlatform
      # still references it (restrict_with_error dependency). Canonical
      # rows can't be deleted.
      #
      # Reference: i-would-like-to-zesty-glade.md Tier 1 — T1.A.
      class ArchitectureDeleteExecutor
        def self.descriptor
          {
            name: "architecture_delete",
            description: "Delete a non-canonical architecture. Fails if any NodePlatform still references it. Canonical rows are immutable and return an error.",
            category: "fleet",
            inputs: {
              architecture_id: { type: "string", required: true }
            },
            outputs: {
              deleted: :boolean,
              architecture_id: :string
            }
          }
        end

        def initialize(account:, agent: nil, user: nil)
          @account = account
          @agent   = agent
          @user    = user
        end

        def execute(architecture_id:)
          tool = ::Ai::Tools::SystemArchitectureCatalogTool.new(
            account: @account, agent: @agent, user: @user
          )
          result = tool.execute(params: {
            action: "system_delete_architecture",
            architecture_id: architecture_id
          })

          if result[:success]
            { success: true, data: result[:data] }
          else
            { success: false, error: result[:error] }
          end
        rescue StandardError => e
          Rails.logger.error("[ArchitectureDeleteExecutor] #{e.class}: #{e.message}")
          { success: false, error: e.message }
        end
      end
    end
  end
end
