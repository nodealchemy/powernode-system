# frozen_string_literal: true

module Api
  module V1
    module System
      # Operator-facing entry point for the System Concierge.
      #
      # The Concierge itself runs on the platform's Ai::ConciergeService /
      # Ai::ConciergeToolBridge stack — this controller's only job is to
      # bootstrap (or reuse) a conversation for the System Concierge agent
      # and surface a current fleet snapshot the operator UI can display
      # alongside the chat. Subsequent messages use the standard
      # /api/v1/ai/conversations/:id/messages endpoint.
      #
      # Reference: comprehensive stabilization sweep Phase 10.3.
      class ConciergeController < BaseController
        before_action :set_account

        # POST /api/v1/system/concierge/start
        #
        # Returns:
        #   conversation_id, agent_id, agent_name, snapshot
        # The snapshot is a Markdown-formatted string the operator UI can
        # render as a starter info card. The conversation history stays
        # clean — the LLM dispatches tools on demand for deeper queries.
        def start
          require_permission("system.fleet.read")

          agent = find_concierge_agent
          return render_error("System Concierge agent not seeded; run rails db:seed", status: :precondition_failed) unless agent

          ::Ai::ProviderAvailabilityService.validate_agent_provider!(agent)
          conversation = find_or_create_conversation(agent)
          snapshot = ::System::Concierge::FleetContextBuilder.build(account: @account)

          render_success(
            conversation_id: conversation.conversation_id,
            agent_id: agent.id,
            agent_name: agent.name,
            snapshot: snapshot
          )
        rescue ::Ai::ProviderAvailabilityService::ProviderUnavailableError => e
          render_error(e.message, status: :precondition_failed)
        end

        private

        def set_account
          @account = current_user.account
        end

        def find_concierge_agent
          @account.ai_agents.find_by(
            name: "System Concierge",
            agent_type: "assistant"
          )
        end

        # Reuse the user's existing active Concierge conversation when it
        # exists; otherwise create a new one. Avoids accumulating stale
        # conversations when the operator reopens the panel repeatedly.
        def find_or_create_conversation(agent)
          existing = agent.conversations
                          .where(user_id: current_user.id, status: "active")
                          .order(last_activity_at: :desc)
                          .first
          return existing if existing

          agent.conversations.create!(
            conversation_id: SecureRandom.uuid,
            user_id: current_user.id,
            account_id: @account.id,
            ai_provider_id: agent.ai_provider_id,
            status: "active",
            conversation_type: "agent",
            title: "System Concierge",
            conversation_context: { "kind" => "system_concierge" },
            last_activity_at: Time.current
          )
        end
      end
    end
  end
end
