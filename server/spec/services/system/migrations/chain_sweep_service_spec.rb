# frozen_string_literal: true

require "rails_helper"

# P9.5 — System::Migrations::ChainSweepService spec.
#
# Locks the per-tick advancement semantics:
#   - planned + in_flight chains advance one hop per tick
#   - terminal chains (completed/failed/cancelled) are skipped
#   - per-chain failures don't poison the sweep
#   - stalled chains are skipped (governance surfaces them instead)
RSpec.describe ::System::Migrations::ChainSweepService, type: :service do
  let(:account) { create(:account) }

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

  before do
    # Every hop reports success — the executor delegates to ApplyExecutor.
    allow(::System::Migrations::ApplyExecutor).to receive(:apply!).and_return(
      ::Struct.new(:ok?, :applied_count, :skipped_count, keyword_init: true).new(
        ok?: true, applied_count: 1, skipped_count: 0
      )
    )
  end

  def make_chain
    ::System::Migrations::ChainComposer.compose!(
      account: account,
      hop_peer_ids: [ nil, peer_b.id, peer_c.id ],
      root_resource_kind: "skill",
      root_resource_id: SecureRandom.uuid
    ).chain
  end

  describe ".run!" do
    it "advances one hop per active chain per tick" do
      chain_a = make_chain
      chain_b = make_chain

      result = described_class.run!(account: account)
      expect(result.swept).to eq(2)
      expect(result.advanced).to eq(2)
      expect(result.failed).to eq(0)

      [ chain_a, chain_b ].each(&:reload)
      expect(chain_a.current_hop_index).to eq(1)
      expect(chain_a.status).to eq("in_flight")
      expect(chain_b.current_hop_index).to eq(1)
    end

    it "transitions to completed when the last hop lands" do
      chain = make_chain
      # First tick → advance to hop 1
      described_class.run!(account: account)
      # Second tick → advance to hop 2 and complete
      result = described_class.run!(account: account)
      chain.reload
      expect(chain.status).to eq("completed")
      expect(result.completed).to eq(1)
    end

    it "skips terminal chains" do
      chain = make_chain
      chain.update!(status: "completed", completed_at: ::Time.current)
      result = described_class.run!(account: account)
      expect(result.swept).to eq(0)
    end

    it "records per-chain failures without poisoning the sweep" do
      chain_ok    = make_chain
      chain_bad   = make_chain

      # Override the global stub for one specific chain by matching on
      # the migration's chain.
      bad_hop = chain_bad.migrations.find_by(chain_position: 0)
      allow(::System::Migrations::ApplyExecutor).to receive(:apply!) do |args|
        if args[:migration]&.id == bad_hop.id
          ::Struct.new(:ok?, :error, keyword_init: true).new(ok?: false, error: "boom")
        else
          ::Struct.new(:ok?, :applied_count, :skipped_count, keyword_init: true).new(
            ok?: true, applied_count: 1, skipped_count: 0
          )
        end
      end

      result = described_class.run!(account: account)
      expect(result.swept).to eq(2)
      expect(result.advanced).to eq(1)
      expect(result.failed).to eq(1)
      expect(result.failures.first[:chain_id]).to eq(chain_bad.id)
      expect(chain_ok.reload.current_hop_index).to eq(1)
      expect(chain_bad.reload.status).to eq("failed")
    end

    it "skips stalled chains (in_flight with no progress beyond threshold)" do
      chain = make_chain
      # Fake a chain that's been in_flight for 2h. We also overwrite the
      # audit_log (composer stamped a fresh chain_composed entry at
      # now()); without aging that, the stall anchor stays fresh and the
      # chain looks active.
      chain.update!(
        status:            "in_flight",
        started_at:        2.hours.ago,
        current_hop_index: 1,
        audit_log:         [ { "event" => "chain_started", "at" => 2.hours.ago.iso8601 } ]
      )

      result = described_class.run!(account: account)
      expect(result.swept).to eq(1)
      expect(result.advanced).to eq(0)
      chain.reload
      expect(chain.current_hop_index).to eq(1) # untouched
    end

    it "scopes to the given account" do
      mine = make_chain
      other_account = create(:account)
      other_peer_b = ::System::FederationPeer.create!(
        account: other_account,
        remote_instance_url: "https://other-b.example.com",
        peer_kind: "platform", spawn_role: "symmetric", spawn_mode: "out_of_band",
        status: "active"
      )
      other_peer_c = ::System::FederationPeer.create!(
        account: other_account,
        remote_instance_url: "https://other-c.example.com",
        peer_kind: "platform", spawn_role: "symmetric", spawn_mode: "out_of_band",
        status: "active"
      )
      ::System::Migrations::ChainComposer.compose!(
        account: other_account,
        hop_peer_ids: [ nil, other_peer_b.id, other_peer_c.id ],
        root_resource_kind: "skill",
        root_resource_id: SecureRandom.uuid
      )

      result = described_class.run!(account: account)
      expect(result.swept).to eq(1) # only this account's chain
      mine.reload
      expect(mine.current_hop_index).to eq(1)
    end
  end
end
