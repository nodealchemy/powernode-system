# frozen_string_literal: true

require "rails_helper"

# P9.5 — System::Migrations::ChainExecutor spec.
#
# Locks the chain state machine + per-hop dispatch. Uses a stub
# ApplyExecutor to control hop outcomes deterministically.
RSpec.describe ::System::Migrations::ChainExecutor, type: :service do
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

  let(:chain) do
    ::System::Migrations::ChainComposer.compose!(
      account: account,
      hop_peer_ids: [ nil, peer_b.id, peer_c.id ],
      root_resource_kind: "skill",
      root_resource_id: SecureRandom.uuid
    ).chain
  end

  before do
    # Default: every hop reports success. Individual tests override.
    @apply_outcomes = []
    allow(::System::Migrations::ApplyExecutor).to receive(:apply!) do |args|
      outcome = @apply_outcomes.shift ||
                ::Struct.new(:ok?, :applied_count, :skipped_count, keyword_init: true).new(
                  ok?: true, applied_count: 1, skipped_count: 0
                )
      outcome
    end
  end

  describe ".advance!" do
    it "advances one hop on success and transitions chain to in_flight" do
      result = described_class.advance!(chain: chain)
      expect(result.ok?).to be(true)
      expect(result.advanced_to).to eq(1)

      chain.reload
      expect(chain.status).to eq("in_flight")
      expect(chain.current_hop_index).to eq(1)
      events = chain.audit_log.map { |e| e["event"] }
      expect(events).to include("chain_started", "hop_applied")
    end

    it "completes the chain when the final hop succeeds" do
      # First hop
      described_class.advance!(chain: chain)
      # Final hop
      result = described_class.advance!(chain: chain.reload)
      expect(result.ok?).to be(true)
      chain.reload
      expect(chain.status).to eq("completed")
      expect(chain.current_hop_index).to eq(chain.total_hops)
      expect(chain.audit_log.last["event"]).to eq("chain_completed")
    end

    it "stops at the failing hop and records chain_failed" do
      @apply_outcomes = [
        ::Struct.new(:ok?, :applied_count, :skipped_count, keyword_init: true).new(
          ok?: true, applied_count: 1, skipped_count: 0
        ),
        ::Struct.new(:ok?, :error, keyword_init: true).new(ok?: false, error: "remote NACK"),
      ]
      # First hop ok → advances to index 1
      described_class.advance!(chain: chain)
      # Second hop fails → chain status becomes failed
      result = described_class.advance!(chain: chain.reload)
      expect(result.ok?).to be(false)
      chain.reload
      expect(chain.status).to eq("failed")
      # UUID currently lives at hop K-1's destination (peer_b).
      # current_hop_index is the position that was attempted.
      expect(chain.current_hop_index).to eq(1)
      expect(chain.audit_log.last["event"]).to eq("chain_failed")
      expect(chain.error_message).to match(/remote NACK/)
    end

    it "no-ops gracefully on a terminal chain" do
      chain.update!(status: "completed", completed_at: ::Time.current)
      result = described_class.advance!(chain: chain)
      expect(result.ok?).to be(false)
      expect(result.error).to match(/is completed/)
    end
  end

  describe ".run_to_completion!" do
    it "walks all hops sequentially and reports the final position" do
      result = described_class.run_to_completion!(chain: chain)
      expect(result.ok?).to be(true)
      chain.reload
      expect(chain.status).to eq("completed")
      expect(chain.audit_log.count { |e| e["event"] == "hop_applied" }).to eq(chain.total_hops)
    end

    it "stops at the first failing hop" do
      @apply_outcomes = [
        ::Struct.new(:ok?, :error, keyword_init: true).new(ok?: false, error: "boom"),
      ]
      result = described_class.run_to_completion!(chain: chain)
      expect(result.ok?).to be(false)
      expect(result.error).to match(/boom/)
      chain.reload
      expect(chain.status).to eq("failed")
    end
  end
end
