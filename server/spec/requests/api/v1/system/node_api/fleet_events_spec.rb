# frozen_string_literal: true

require "rails_helper"

# Exercises the agent-side fleet event ingestion endpoint added in
# Phase 0 of the agent stub implementation plan. Confirms:
#   - JWT auth gates the endpoint
#   - Events are persisted via Fleet::EventBroadcaster with source: "agent"
#   - Events are scoped to current_instance.account + node_instance_id
#   - Batch with mixed valid/invalid entries returns the count written
RSpec.describe "Api::V1::System::NodeApi::Fleet#events", type: :request do
  let(:account)       { create(:account) }
  let(:node_template) { create(:system_node_template, account: account) }
  let(:node)          { create(:system_node, account: account, node_template: node_template) }
  let(:instance)      { create(:system_node_instance, node: node, status: "running") }
  let(:auth_token) do
    ::Security::JwtService.encode({
      sub:     instance.id,
      type:    "instance",
      version: ::Security::JwtService::CURRENT_TOKEN_VERSION
    })
  end
  let(:headers) { { "X-Instance-Token" => auth_token } }

  describe "POST /api/v1/system/node_api/fleet/events" do
    it "rejects unauthenticated requests" do
      post "/api/v1/system/node_api/fleet/events",
           params: { events: [{ kind: "test.event" }] },
           as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it "persists a single event with the agent source" do
      expect {
        post "/api/v1/system/node_api/fleet/events",
             params: { events: [{ kind: "module.attached", severity: "low",
                                  payload: { module_id: "abc-123" } }] },
             headers: headers,
             as: :json
      }.to change { ::System::FleetEvent.count }.by(1)

      expect(response).to have_http_status(:ok)
      event = ::System::FleetEvent.last
      expect(event.kind).to eq("module.attached")
      expect(event.source).to eq("agent")
      expect(event.account_id).to eq(account.id)
      expect(event.node_instance_id).to eq(instance.id)
      expect(event.payload["module_id"]).to eq("abc-123")
    end

    it "ignores client-provided source/account fields and forces agent + current_instance" do
      post "/api/v1/system/node_api/fleet/events",
           params: { events: [{
             kind: "test.event",
             severity: "high",
             source: "operator",
             account_id: "rogue-account",
             node_instance_id: "rogue-instance",
             payload: { foo: "bar" }
           }] },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:ok)
      event = ::System::FleetEvent.last
      expect(event.source).to eq("agent")
      expect(event.account_id).to eq(account.id)
      expect(event.node_instance_id).to eq(instance.id)
    end

    it "accepts a batch and returns the count written" do
      post "/api/v1/system/node_api/fleet/events",
           params: { events: [
             { kind: "module.attached", severity: "low" },
             { kind: "module.detached", severity: "medium" }
           ] },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json.dig("data", "written")).to eq(2)
      expect(json.dig("data", "requested")).to eq(2)
      expect(::System::FleetEvent.where(node_instance_id: instance.id).count).to eq(2)
    end

    it "skips entries missing :kind without aborting the batch" do
      post "/api/v1/system/node_api/fleet/events",
           params: { events: [
             { kind: "valid.event", severity: "low" },
             { severity: "low" }, # no kind
             { kind: "another.valid", severity: "low" }
           ] },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json.dig("data", "written")).to eq(2)
      expect(json.dig("data", "requested")).to eq(3)
    end

    it "returns 422 for empty events array" do
      post "/api/v1/system/node_api/fleet/events",
           params: { events: [] },
           headers: headers,
           as: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "defaults severity to low when omitted" do
      post "/api/v1/system/node_api/fleet/events",
           params: { events: [{ kind: "test.event" }] },
           headers: headers,
           as: :json
      expect(response).to have_http_status(:ok)
      expect(::System::FleetEvent.last.severity).to eq("low")
    end
  end
end
