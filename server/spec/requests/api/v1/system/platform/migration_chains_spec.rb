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
      expect(response).to have_http_status(:unprocessable_content)
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
      expect(response).to have_http_status(:unprocessable_content)
    end

    # IMP-0b89e9418f64. The controller header claimed cancel was legal from
    # planned OR in_flight; the model's TRANSITIONS allow in_flight → completed
    # or failed only, so an operator cancelling a chain that is mid-hop — the
    # STALLED chain the whole operator surface exists for — is refused. The
    # header was the wrong half; the behaviour is deliberate, because
    # cancelling mid-hop needs a defined rollback of the hop in flight and none
    # exists. This pins the refusal AND its reason so the two cannot drift
    # apart again silently.
    it "422s an in_flight chain, naming the state, since mid-hop cancel has no rollback" do
      chain.update!(status: "in_flight", started_at: ::Time.current)

      post "#{base}/#{chain.id}/cancel", headers: auth_headers_for(canceller)

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to eq("Chain is in_flight and cannot be cancelled")
      expect(chain.reload.status).to eq("in_flight")
    end

    it "keeps the model as the single source of truth for what cancel accepts" do
      # The controller gates on can_transition_to?, so the model's table is the
      # only place the legal set is defined. A header or a UI that disagrees is
      # the thing that is wrong.
      expect(::System::MigrationChain::TRANSITIONS.fetch("planned")).to include("cancelled")
      expect(::System::MigrationChain::TRANSITIONS.fetch("in_flight")).not_to include("cancelled")
    end

    it "forbids without cancel permission" do
      post "#{base}/#{chain.id}/cancel", headers: auth_headers_for(operator)
      expect(response).to have_http_status(:forbidden)
    end
  end

  # The header is documentation an operator and a UI author both read; a stale
  # claim here is what sent the chains UI looking for an in-flight cancel.
  describe "controller documentation" do
    it "does not claim cancel is legal from in_flight" do
      # Force the autoload FIRST: config.eager_load is off in test unless CI,
      # and const_source_location on a not-yet-loaded constant reports
      # Zeitwerk's shim (zeitwerk/cref.rb) rather than the source file — which
      # would make the negative arm below pass vacuously. Same precedent as
      # spec/lib/powernode/gate_registry_coherence_spec.rb. Reading the file
      # that DEFINES the class also means no relative path to rot.
      ::Api::V1::System::Platform::MigrationChainsController
      path, = Object.const_source_location(
        "Api::V1::System::Platform::MigrationChainsController"
      )
      raise "controller has no source location" if path.nil?
      expect(path).to end_with("migration_chains_controller.rb")
      source = File.read(path)
      expect(source).not_to include("planned/in_flight → cancelled")
      expect(source).to include("planned → cancelled")
    end
  end
end
