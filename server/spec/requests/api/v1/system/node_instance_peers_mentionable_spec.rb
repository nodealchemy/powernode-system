# frozen_string_literal: true

require "rails_helper"

# Phase 10.7 — peer-mirror Ai::Agent surface for the parent platform's
# workspace mention picker.
RSpec.describe "GET /api/v1/system/node_instance_peers/mentionable", type: :request do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:user) { user_with_permissions("system.peers.read", account: account) }
  let(:headers) { auth_headers_for(user) }

  let!(:provider) { ::Ai::Provider.first || create(:ai_provider) }

  def create_mirror(account:, name:, status: "active")
    creator = ::User.where(account_id: account.id).first || create(:user, account: account)
    ::Ai::Agent.create!(
      account: account, name: name, agent_type: "assistant",
      status: status, creator: creator, provider: provider,
      metadata: { "kind" => "system_node_peer", "peer_id" => SecureRandom.uuid }
    )
  end

  it "returns peer-mirror agents in MentionMember shape" do
    create_mirror(account: account, name: "instance-aaaaaaaa")
    create_mirror(account: account, name: "instance-bbbbbbbb")

    get "/api/v1/system/node_instance_peers/mentionable", headers: headers

    expect(response).to have_http_status(:ok)
    members = JSON.parse(response.body).dig("data", "members")
    names = members.map { |m| m["name"] }
    expect(names).to contain_exactly("instance-aaaaaaaa", "instance-bbbbbbbb")
    expect(members.first.keys).to include("id", "name", "role", "agent_type", "peer_id", "node_instance_id")
    expect(members.first["role"]).to eq("node_peer")
    expect(members.first["agent_type"]).to eq("node_peer")
  end

  it "excludes archived peer mirrors" do
    create_mirror(account: account, name: "instance-active")
    create_mirror(account: account, name: "instance-archived", status: "archived")

    get "/api/v1/system/node_instance_peers/mentionable", headers: headers

    names = JSON.parse(response.body).dig("data", "members").map { |m| m["name"] }
    expect(names).to contain_exactly("instance-active")
  end

  it "isolates per-account (no cross-tenant leak)" do
    create_mirror(account: account, name: "instance-mine")
    create_mirror(account: other_account, name: "instance-foreign")

    get "/api/v1/system/node_instance_peers/mentionable", headers: headers

    names = JSON.parse(response.body).dig("data", "members").map { |m| m["name"] }
    expect(names).to contain_exactly("instance-mine")
  end

  it "excludes regular Ai::Agents that aren't peer mirrors" do
    creator = create(:user, account: account)
    ::Ai::Agent.create!(
      account: account, name: "Regular Agent", agent_type: "assistant",
      status: "active", creator: creator, provider: provider,
      metadata: { "kind" => "operator_assistant" }
    )

    get "/api/v1/system/node_instance_peers/mentionable", headers: headers

    names = JSON.parse(response.body).dig("data", "members").map { |m| m["name"] }
    expect(names).not_to include("Regular Agent")
  end

  it "returns 401 without authentication" do
    get "/api/v1/system/node_instance_peers/mentionable"
    expect(response).to have_http_status(:unauthorized)
  end
end
