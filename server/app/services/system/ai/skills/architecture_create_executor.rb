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
      class ArchitectureCreateExecutor
        def self.descriptor
          {
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

        def execute(name:, family:, apt_name: nil, rpm_name: nil, display_name: nil, description: nil, enabled: nil, public: nil)
          tool = ::Ai::Tools::SystemArchitectureCatalogTool.new(
            account: @account, agent: @agent, user: @user
          )
          params = { action: "system_create_architecture",
                     name: name, family: family,
                     apt_name: apt_name, rpm_name: rpm_name,
                     display_name: display_name, description: description }
          params[:enabled] = enabled unless enabled.nil?
          params[:public]  = public  unless public.nil?

          result = tool.execute(params: params)

          if result[:success]
            { success: true, data: result[:data] }
          else
            { success: false, error: result[:error] }
          end
        rescue StandardError => e
          Rails.logger.error("[ArchitectureCreateExecutor] #{e.class}: #{e.message}")
          { success: false, error: e.message }
        end
      end
    end
  end
end
