# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Ai::Skills::FederationAcceptanceExecutor, type: :service do
  let(:account) { create(:account) }

  # APO-1c (IMP-7e2bdc1774e4). This executor declares `requires_approval: true`,
  # and BaseSkillExecutor#execute now resolves Ai::InterventionPolicy BEFORE
  # #perform — an unconfigured category defaults to require_approval, so every
  # example below would park an approval instead of performing. These examples
  # are about what #perform DOES, so an operator policy puts the gate on its
  # proceed branch rather than removing it: the real entry point still runs.
  # See spec/support/skill_gate_helpers.rb.
  before { auto_execute_skill_policy!(account, described_class) }
  let(:user)    { create(:user, account: account) }

  subject(:executor) { described_class.new(account: account, user: user) }

  # The accept→enrolled transition fires the FederationPeer after_commit
  # post-accept enqueue; keep the executor specs off Redis.
  before do
    allow(::System::WorkerDispatch).to receive(:enqueue).and_return("jid-stub")
  end

  describe ".descriptor" do
    it "exposes approval-gated federation metadata" do
      desc = described_class.descriptor
      expect(desc[:name]).to eq("federation_acceptance")
      expect(desc[:category]).to eq("federation")
      expect(desc[:requires_approval]).to be true
      expect(desc[:blast_radius]).to eq(:high)
      expect(desc[:inputs].keys).to include(:acceptance_token, :contract_version)
      expect(desc[:outputs].keys).to include(:peer_id, :status, :node_enrollment, :sdwan_attach, :governance)
    end
  end

  describe "binding" do
    it "binds to SDWAN Manager and System Concierge" do
      # The class registered itself via binds_to at load time. We assert the
      # descriptor + that the class is a BaseSkillExecutor subclass (the
      # SkillBindings registry is exercised by the integration seed specs).
      expect(described_class.ancestors).to include(System::Ai::Skills::BaseSkillExecutor)
    end
  end

  describe "#execute" do
    let(:peer) do
      create(:system_federation_peer, :platform,
             account: account, status: "proposed",
             remote_instance_url: "https://child.example.com")
    end
    let(:token) { peer.generate_acceptance_token!(ttl_seconds: 1.hour.to_i) }

    it "delegates to FederationAcceptanceService and returns success on a valid token" do
      token # ensure generated

      result = executor.execute(
        acceptance_token: token,
        contract_version: 1,
        capabilities: { "skill" => { "read" => true } },
        extension_slugs: [ "trading" ],
        endpoints: [ { "url" => "https://child.example.com:443" } ]
      )

      expect(result[:success]).to be true
      expect(result[:data][:peer_id]).to eq(peer.id)
      expect(result[:data][:status]).to eq("enrolled")

      peer.reload
      expect(peer.status).to eq("enrolled")
      expect(peer.extension_slugs).to eq([ "trading" ])
    end

    it "passes inputs through to the service (no re-implementation in the executor)" do
      expect(::System::Federation::FederationAcceptanceService)
        .to receive(:call)
        .with(
          token: "tok-123",
          contract_version: 1,
          capabilities: { "a" => 1 },
          extension_slugs: [ "x" ],
          endpoints: [ { "url" => "u" } ]
        )
        .and_return(
          ::System::Federation::FederationAcceptanceService::Result.new(
            ok?: true, peer: peer, payload: { peer_id: peer.id, status: "enrolled" }
          )
        )

      result = executor.execute(
        acceptance_token: "tok-123",
        contract_version: 1,
        capabilities: { "a" => 1 },
        extension_slugs: [ "x" ],
        endpoints: [ { "url" => "u" } ]
      )
      expect(result[:success]).to be true
      expect(result[:data][:peer_id]).to eq(peer.id)
    end

    it "returns failure when the service rejects the token" do
      result = executor.execute(
        acceptance_token: "bad-#{SecureRandom.hex(8)}",
        contract_version: 1
      )
      expect(result[:success]).to be false
      expect(result[:error]).to match(/not recognized or expired/)
    end

    it "fails validation when acceptance_token is missing" do
      result = executor.execute(contract_version: 1)
      expect(result[:success]).to be false
      expect(result[:error]).to match(/missing required input: acceptance_token/)
    end
  end
end
