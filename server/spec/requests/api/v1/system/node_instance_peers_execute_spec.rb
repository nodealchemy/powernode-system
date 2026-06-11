# frozen_string_literal: true

require "rails_helper"

# Audit F6-05 — POST /node_instance_peers/:id/execute returned 202
# "Task dispatched; result will arrive via /node_api/peer/execute_result"
# while creating NO System::Task and dispatching nothing — every caller
# got a false success and the result never arrived. The endpoint must
# enqueue a real a2a_call Task (the delegate! recipe: minted capability
# token + task addressed to the peer's instance) or fail honestly.
RSpec.describe "Api::V1::System::NodeInstancePeers#execute", type: :request do
  let(:user)    { user_with_permissions("system.peers.execute") }
  let(:account) { user.account }
  let(:headers) { auth_headers_for(user) }

  let(:node)     { create(:system_node, account: account) }
  let(:instance) { create(:system_node_instance, :running, node: node) }

  def peer_for(inst, declared_skills: [], granted: [], **attrs)
    System::NodeInstancePeer.create!(
      node_instance: inst, account: account, handle: "peer-#{SecureRandom.hex(3)}",
      status: "active", enabled: true, trust_score: 0.5, daily_decision_budget: 10,
      declared_skills: declared_skills,
      addresses: [ "https://10.0.0.9:8443" ],
      **attrs
    ).tap { |p| p.grant_peer_skills!(granted) if granted.any? }
  end

  def execute!(peer, params)
    post "/api/v1/system/node_instance_peers/#{peer.id}/execute",
         params: params, headers: headers, as: :json
  end

  describe "real dispatch (self-edge a2a_call)" do
    let(:peer) do
      peer_for(instance,
               declared_skills: [ { "name" => "echo-task" } ],
               granted: %w[echo-task])
    end

    it "mints a capability token, enqueues an a2a_call Task on the peer's instance, and returns its id" do
      expect {
        execute!(peer, { skill: "echo-task", input: { "text" => "ping" } })
      }.to change { System::Task.where(command: "a2a_call").count }.by(1)

      expect(response).to have_http_status(:accepted)

      task = System::Task.where(command: "a2a_call").order(created_at: :desc).first
      expect(task.operable_id).to eq(instance.id)
      expect(task.status).to eq("pending")
      expect(task.options["skill"]).to eq("echo-task")
      expect(task.options["target_instance_id"]).to eq(instance.id)
      expect(task.options["target_addresses"]).to eq([ "https://10.0.0.9:8443" ])
      expect(task.options["args"]).to eq({ "text" => "ping" })
      # The agent hard-requires {envelope, signature} — a task without them
      # is rejected by the a2a_call handler before any network call.
      expect(task.options.dig("capability_token", "envelope")).to be_present
      expect(task.options.dig("capability_token", "signature")).to be_present

      expect(json_response_data["task_id"]).to eq(task.id)
    end

    it "refuses honestly (403, no Task) when the capability policy denies the edge" do
      ungranted = peer_for(create(:system_node_instance, :running, node: node),
                           declared_skills: [ { "name" => "echo-task" } ])

      expect {
        execute!(ungranted, { skill: "echo-task" })
      }.not_to change { System::Task.count }

      expect(response).to have_http_status(:forbidden)
      expect(json_response["error"]).to match(/not granted skill/i)
    end
  end

  describe "existing validation gates (pinned)" do
    it "rejects a skill the peer does not declare" do
      peer = peer_for(instance, declared_skills: [ { "name" => "other" } ])

      execute!(peer, { skill: "echo-task" })

      expect(response).to have_http_status(:unprocessable_content)
      expect(System::Task.where(command: "a2a_call")).to be_empty
    end

    it "rejects a disabled peer with 412" do
      peer = peer_for(instance, declared_skills: [ { "name" => "echo-task" } ])
      peer.update!(enabled: false, status: "registered")

      execute!(peer, { skill: "echo-task" })

      expect(response).to have_http_status(:precondition_failed)
    end

    it "requires the system.peers.execute permission" do
      peer = peer_for(instance, declared_skills: [ { "name" => "echo-task" } ])
      other = user_with_permissions("system.peers.read")

      post "/api/v1/system/node_instance_peers/#{peer.id}/execute",
           params: { skill: "echo-task" }, headers: auth_headers_for(other), as: :json

      expect(response).to have_http_status(:forbidden).or have_http_status(:not_found)
    end
  end
end
