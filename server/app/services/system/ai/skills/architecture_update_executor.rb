# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Update a non-canonical architecture's fields. Canonical rows
      # (the seven seeded ones) are immutable — the executor will
      # return an error if asked to mutate one.
      #
      # Reference: i-would-like-to-zesty-glade.md Tier 1 — T1.A.
      class ArchitectureUpdateExecutor
        def self.descriptor
          {
            name: "architecture_update",
            description: "Update a non-canonical architecture's fields. Canonical rows are immutable and return an error.",
            category: "fleet",
            inputs: {
              architecture_id: { type: "string", required: true },
              attributes:      { type: "object", required: true,
                                  description: "Allowed: name, family, apt_name, rpm_name, display_name, description, kernel_options, enabled, public" }
            },
            outputs: {
              architecture: :object
            }
          }
        end

        def initialize(account:, agent: nil, user: nil)
          @account = account
          @agent   = agent
          @user    = user
        end

        def execute(architecture_id:, attributes:)
          tool = ::Ai::Tools::SystemArchitectureCatalogTool.new(
            account: @account, agent: @agent, user: @user
          )
          result = tool.execute(params: {
            action: "system_update_architecture",
            architecture_id: architecture_id,
            attributes: attributes
          })

          if result[:success]
            { success: true, data: result[:data] }
          else
            { success: false, error: result[:error] }
          end
        rescue StandardError => e
          Rails.logger.error("[ArchitectureUpdateExecutor] #{e.class}: #{e.message}")
          { success: false, error: e.message }
        end
      end
    end
  end
end
