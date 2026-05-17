# frozen_string_literal: true

require "rails_helper"

# P9.5 — System::Migrations::ChainComposer spec.
#
# Locks the chain envelope creation: N peers → N-1 hops, each linked
# back to the chain with chain_position 0..N-2. Validation errors
# (too few peers, duplicates, bad operation) surface cleanly.
RSpec.describe ::System::Migrations::ChainComposer, type: :service do
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
  let(:peer_d) { make_peer("d") }

  describe ".compose!" do
    it "composes a 3-hop chain (self → b → c → d) with 3 Migration rows" do
      result = described_class.compose!(
        account: account,
        hop_peer_ids: [ nil, peer_b.id, peer_c.id, peer_d.id ],
        root_resource_kind: "skill",
        root_resource_id: SecureRandom.uuid
      )
      expect(result.ok?).to be(true)
      chain = result.chain
      expect(chain.total_hops).to eq(3)
      expect(chain.current_hop_index).to eq(0)
      expect(chain.status).to eq("planned")

      hops = chain.migrations.order(:chain_position)
      expect(hops.size).to eq(3)
      expect(hops.map(&:destination_peer_id)).to eq([ peer_b.id, peer_c.id, peer_d.id ])
      expect(hops.map(&:chain_position)).to eq([ 0, 1, 2 ])
      expect(hops.map(&:status).uniq).to eq([ "planned" ])
    end

    it "appends a chain_composed audit entry" do
      result = described_class.compose!(
        account: account,
        hop_peer_ids: [ nil, peer_b.id, peer_c.id ],
        root_resource_kind: "skill",
        root_resource_id: SecureRandom.uuid
      )
      entry = result.chain.audit_log.first
      expect(entry["event"]).to eq("chain_composed")
      expect(entry["hop_count"]).to eq(2)
    end

    it "rejects a chain with fewer than 2 hop peers" do
      result = described_class.compose!(
        account: account,
        hop_peer_ids: [ peer_b.id ],
        root_resource_kind: "skill",
        root_resource_id: SecureRandom.uuid
      )
      expect(result.ok?).to be(false)
      expect(result.error).to match(/at least 2 hop peer ids/)
    end

    it "rejects a chain with duplicate peer ids" do
      result = described_class.compose!(
        account: account,
        hop_peer_ids: [ nil, peer_b.id, peer_b.id ],
        root_resource_kind: "skill",
        root_resource_id: SecureRandom.uuid
      )
      expect(result.ok?).to be(false)
      expect(result.error).to match(/duplicate hop peer/)
    end

    it "rejects an unknown operation" do
      result = described_class.compose!(
        account: account,
        hop_peer_ids: [ nil, peer_b.id ],
        root_resource_kind: "skill",
        root_resource_id: SecureRandom.uuid,
        operation: "warp"
      )
      expect(result.ok?).to be(false)
      expect(result.error).to match(/operation must be one of/)
    end
  end
end
