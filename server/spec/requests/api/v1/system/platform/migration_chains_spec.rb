# frozen_string_literal: true

require "rails_helper"

# P9.5 — Operator surface for multi-hop migration chains.
RSpec.describe "Api::V1::System::Platform::MigrationChains", type: :request do
  let(:account)   { create(:account) }
  let(:reader)    { user_with_permissions("system.platform.read", account: account) }
  let(:operator)  { user_with_permissions("system.platform.read", "system.migrations.apply", account: account) }
  let(:canceller) { user_with_permissions("system.platform.read", "system.migrations.cancel", account: account) }
  let(:base)      { "/api/v1/system/platform/migration_chains" }

  def make_peer(label)
    ::System::FederationPeer.create!(
      account: account,
      remote_instance_url: "https://#{label}-#{SecureRandom.hex(4)}.example.com",
      peer_kind: "platform",
      spawn_role: "symmetric", spawn_mode: "out_of_band",
      status: "active"
    )
  end

  let(:peer_b) { make_peer("b") }
  let(:peer_c) { make_peer("c") }

  def compose_chain
    ::System::Migrations::ChainComposer.compose!(
      account: account,
      hop_peer_ids: [ nil, peer_b.id, peer_c.id ],
      root_resource_kind: "skill",
      root_resource_id: SecureRandom.uuid
    ).chain
  end

  before do
    allow(::System::Migrations::ApplyExecutor).to receive(:apply!).and_return(
      ::Struct.new(:ok?, :applied_count, :skipped_count, keyword_init: true).new(
        ok?: true, applied_count: 1, skipped_count: 0
      )
    )
  end

  describe "GET /migration_chains" do
    let!(:chain_a) { compose_chain }
    let!(:cross_account_chain) do
      other = create(:account)
      o_b = ::System::FederationPeer.create!(
        account: other, remote_instance_url: "https://o-b.example.com",
        peer_kind: "platform", spawn_role: "symmetric", spawn_mode: "out_of_band",
        status: "active"
      )
      o_c = ::System::FederationPeer.create!(
        account: other, remote_instance_url: "https://o-c.example.com",
        peer_kind: "platform", spawn_role: "symmetric", spawn_mode: "out_of_band",
        status: "active"
      )
      ::System::Migrations::ChainComposer.compose!(
        account: other, hop_peer_ids: [ nil, o_b.id, o_c.id ],
        root_resource_kind: "skill", root_resource_id: SecureRandom.uuid
      ).chain
    end

    it "lists this account's chains" do
      get base, headers: auth_headers_for(reader)
      expect(response).to have_http_status(:ok)
      data = json_response_data
      expect(data["count"]).to eq(1)
      expect(data["migration_chains"].first["id"]).to eq(chain_a.id)
    end

    it "filters by status" do
      chain_a.update!(status: "completed", completed_at: ::Time.current)
      get base, headers: auth_headers_for(reader), params: { status: "completed" }
      expect(json_response_data["migration_chains"].map { |c| c["status"] }).to eq([ "completed" ])
    end

    it "forbids without read permission" do
      anon = create(:user, account: account)
      get base, headers: auth_headers_for(anon)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET /migration_chains/:id" do
    let!(:chain) { compose_chain }

    it "returns full detail with hops + audit_log" do
      get "#{base}/#{chain.id}", headers: auth_headers_for(reader)
      expect(response).to have_http_status(:ok)
      data = json_response_data["migration_chain"]
      expect(data["total_hops"]).to eq(2)
      expect(data["hops"].size).to eq(2)
      expect(data["audit_log"].first["event"]).to eq("chain_composed")
    end

    it "404s for unknown id" do
      get "#{base}/nonexistent", headers: auth_headers_for(reader)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /migration_chains" do
    # `hop_peer_ids` in the public API carries only destination peers
    # (the implicit "self" origin is prepended server-side).
    it "composes a chain" do
      post base, headers: auth_headers_for(operator), as: :json, params: {
        hop_peer_ids: [ peer_b.id, peer_c.id ],
        root_resource_kind: "skill",
        root_resource_id: SecureRandom.uuid,
        operation: "migrate"
      }
      expect(response).to have_http_status(:created)
      data = json_response_data["migration_chain"]
      expect(data["total_hops"]).to eq(2)
      expect(data["status"]).to eq("planned")
      expect(::System::MigrationChain.find(data["id"]).initiated_by_user_id).to eq(operator.id)
    end

    it "422s on invalid hop_peer_ids" do
      post base, headers: auth_headers_for(operator), as: :json, params: {
        hop_peer_ids: [], # too few — composer needs >=1 destination
        root_resource_kind: "skill",
        root_resource_id: SecureRandom.uuid
      }
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "forbids without apply permission" do
      post base, headers: auth_headers_for(reader), as: :json, params: {
        hop_peer_ids: [ peer_b.id, peer_c.id ],
        root_resource_kind: "skill",
        root_resource_id: SecureRandom.uuid
      }
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /migration_chains/:id/advance" do
    let!(:chain) { compose_chain }

    it "advances one hop" do
      post "#{base}/#{chain.id}/advance", headers: auth_headers_for(operator)
      expect(response).to have_http_status(:ok)
      expect(json_response_data["advanced_to"]).to eq(1)
      chain.reload
      expect(chain.current_hop_index).to eq(1)
      expect(chain.status).to eq("in_flight")
    end

    it "forbids without apply permission" do
      post "#{base}/#{chain.id}/advance", headers: auth_headers_for(reader)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /migration_chains/:id/run" do
    let!(:chain) { compose_chain }

    it "walks to completion" do
      post "#{base}/#{chain.id}/run", headers: auth_headers_for(operator)
      expect(response).to have_http_status(:ok)
      chain.reload
      expect(chain.status).to eq("completed")
      expect(chain.current_hop_index).to eq(chain.total_hops)
    end
  end

  describe "POST /migration_chains/:id/cancel" do
    let!(:chain) { compose_chain }

    it "cancels a planned chain" do
      post "#{base}/#{chain.id}/cancel", headers: auth_headers_for(canceller)
      expect(response).to have_http_status(:ok)
      chain.reload
      expect(chain.status).to eq("cancelled")
      expect(chain.audit_log.last["event"]).to eq("chain_cancelled")
    end

    it "422s a completed chain" do
      chain.update!(status: "completed", completed_at: ::Time.current)
      post "#{base}/#{chain.id}/cancel", headers: auth_headers_for(canceller)
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "forbids without cancel permission" do
      post "#{base}/#{chain.id}/cancel", headers: auth_headers_for(operator)
      expect(response).to have_http_status(:forbidden)
    end
  end
end
