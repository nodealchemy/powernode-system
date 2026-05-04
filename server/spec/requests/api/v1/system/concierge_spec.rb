# frozen_string_literal: true

require "rails_helper"

# Phase 10.3 — System Concierge bootstrap endpoint.
RSpec.describe "Api::V1::System::Concierge", type: :request do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:user) { user_with_permissions("system.fleet.read", account: account) }
  let(:headers) { auth_headers_for(user) }
  let!(:concierge_agent) do
    create(:ai_agent,
           account: account, name: "System Concierge", agent_type: "assistant",
           metadata: { "concierge_tool_filter" => [ "system_*" ] })
  end

  describe "POST /api/v1/system/concierge/start" do
    before do
      # ProviderAvailabilityService asserts a configured provider credential.
      # Test factories don't seed credentials by default; stub the check
      # since credential plumbing isn't what we're verifying here.
      allow(::ProviderAvailabilityService).to receive(:validate_agent_provider!)
    end

    it "creates a new conversation and returns the bootstrap payload" do
      post "/api/v1/system/concierge/start", headers: headers

      expect(response).to have_http_status(:ok)
      data = JSON.parse(response.body).fetch("data")
      expect(data["agent_id"]).to eq(concierge_agent.id)
      expect(data["agent_name"]).to eq("System Concierge")
      expect(data["conversation_id"]).to be_present
      expect(data).to have_key("snapshot")

      conversation = ::Ai::Conversation.find_by(conversation_id: data["conversation_id"])
      expect(conversation.user_id).to eq(user.id)
      expect(conversation.account_id).to eq(account.id)
      expect(conversation.ai_agent_id).to eq(concierge_agent.id)
      expect(conversation.conversation_context["kind"]).to eq("system_concierge")
    end

    it "reuses an existing active Concierge conversation for the same user" do
      post "/api/v1/system/concierge/start", headers: headers
      first_id = JSON.parse(response.body).dig("data", "conversation_id")

      post "/api/v1/system/concierge/start", headers: headers
      second_id = JSON.parse(response.body).dig("data", "conversation_id")

      expect(second_id).to eq(first_id)
    end

    it "creates a new conversation when the previous one is archived" do
      post "/api/v1/system/concierge/start", headers: headers
      first_id = JSON.parse(response.body).dig("data", "conversation_id")

      ::Ai::Conversation.find_by(conversation_id: first_id).update!(status: "archived")

      post "/api/v1/system/concierge/start", headers: headers
      second_id = JSON.parse(response.body).dig("data", "conversation_id")

      expect(second_id).not_to eq(first_id)
    end

    it "isolates per-user conversations within the same account" do
      other_user = user_with_permissions("system.fleet.read", account: account)
      post "/api/v1/system/concierge/start", headers: headers
      user_id = JSON.parse(response.body).dig("data", "conversation_id")

      post "/api/v1/system/concierge/start", headers: auth_headers_for(other_user)
      other_id = JSON.parse(response.body).dig("data", "conversation_id")

      expect(other_id).not_to eq(user_id)
    end

    it "isolates conversations per-account (cross-tenant denial)" do
      foreign_user = user_with_permissions("system.fleet.read", account: other_account)
      post "/api/v1/system/concierge/start", headers: auth_headers_for(foreign_user)

      # Foreign account has no Concierge agent seeded — precondition_failed.
      # Confirms account scoping: the agent in `account` is not visible.
      expect(response).to have_http_status(:precondition_failed)
      expect(response.body).to include("not seeded")
    end

    it "returns 412 when the agent is not seeded" do
      concierge_agent.destroy!
      post "/api/v1/system/concierge/start", headers: headers

      expect(response).to have_http_status(:precondition_failed)
    end

    it "returns 403 without system.fleet.read permission" do
      unprivileged = user_with_permissions("system.modules.read", account: account)
      post "/api/v1/system/concierge/start", headers: auth_headers_for(unprivileged)

      expect(response).to have_http_status(:forbidden)
    end

    it "returns 401 without authentication" do
      post "/api/v1/system/concierge/start"

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
