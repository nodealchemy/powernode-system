# frozen_string_literal: true

module Api
  module V1
    module System
      # Operator-facing entry point for the Infrastructure Generalist
      # (formerly "System Concierge"; source_key is unchanged).
      #
      # The Concierge itself runs on the platform's Ai::ConciergeService /
      # Ai::ConciergeToolBridge stack — this controller's only job is to
      # bootstrap (or reuse) a conversation for that agent
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
          return render_error("Infrastructure Generalist agent not seeded; run rails db:seed", status: :precondition_failed) unless agent

          ::ProviderAvailabilityService.validate_agent_provider!(agent)
          conversation = find_or_create_conversation(agent)
          snapshot = ::System::Concierge::FleetContextBuilder.build(account: @account)

          render_success(
            conversation_id: conversation.conversation_id,
            agent_id: agent.id,
            agent_name: agent.name,
            snapshot: snapshot
          )
        rescue ::ProviderAvailabilityService::ProviderUnavailableError => e
          render_error(e.message, status: :precondition_failed)
        end

        private

        def set_account
          @account = current_user.account
        end

        # HIER-P2I: the account's clone of the canonical — the principal that
        # executes this conversation — never the global row.
        #
        # Resolved by SOURCE KEY, not display name. This used to be
        # `resolve_for(name: "System Concierge")`, which made the operator-
        # visible name a lookup key: renaming the agent turned this into the
        # "not seeded" refusal below even though the row was right there.
        # `source_key` is set explicitly by the seed and derived from nothing,
        # and GloballyScopable#clone_to_account copies it onto an account's
        # clone, so the same key resolves the override and the global.
        #
        # `resolve_for` takes name/slug only, so the override preference is
        # spelled out here rather than routed through it — `for_account` is
        # global + this account, and `account_override_first` puts the
        # account's own row ahead of the global one.
        AGENT_SOURCE_KEY = "system-concierge"

        def find_concierge_agent
          resolved = ::Ai::Agent.for_account(@account.id)
                                .where(source_key: AGENT_SOURCE_KEY, agent_type: "assistant")
                                .account_override_first
                                .first
          ::Ai::Agents::AccountPrincipalResolver.acting(resolved, account: @account, user: current_user)
                                                &.tap { |a| a.resolving_account = @account }
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
            conversation_id: UUID7.generate,
            user_id: current_user.id,
            account_id: @account.id,
            ai_provider_id: agent.ai_provider_id,
            status: "active",
            conversation_type: "agent",
            title: "Infrastructure Generalist",
            conversation_context: { "kind" => "system_concierge" },
            last_activity_at: Time.current
          )
        end
      end
    end
  end
end
