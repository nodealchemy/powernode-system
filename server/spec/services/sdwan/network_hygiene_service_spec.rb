# frozen_string_literal: true

require "rails_helper"

# Increment 13 — overlay hygiene. Mirrors System::InstancePoolService's
# TTL-reaper patterns (recycle_stale_members!) and
# System::StorageMigration.cleanup_grace_hours's 3-tier SiteSetting
# resolution (account override → SiteSetting global → baked-in default).
RSpec.describe Sdwan::NetworkHygieneService do
  let(:account) { create(:account) }
  let(:network) { create(:sdwan_network, account: account) }

  describe ".mark_for_gc!" do
    it "stamps metadata['expires_at'] using the resolved TTL" do
      freeze_time do
        described_class.mark_for_gc!(network, ttl_seconds: 60)
        expect(Time.zone.parse(network.reload.metadata["expires_at"])).to be_within(1.second).of(60.seconds.from_now)
      end
    end

    it "defaults the TTL via default_ttl_seconds when none is given" do
      freeze_time do
        described_class.mark_for_gc!(network)
        expected = described_class::DEFAULT_TTL_SECONDS.seconds.from_now
        expect(Time.zone.parse(network.reload.metadata["expires_at"])).to be_within(1.second).of(expected)
      end
    end
  end

  describe ".default_ttl_seconds" do
    it "falls back to the baked-in default when no override exists" do
      expect(described_class.default_ttl_seconds(account: account)).to eq(described_class::DEFAULT_TTL_SECONDS)
    end

    it "prefers the SiteSetting global default over the baked-in default" do
      SiteSetting.set(described_class::TTL_SETTING_KEY, "3600", setting_type: "integer")
      expect(described_class.default_ttl_seconds(account: account)).to eq(3600)
    end

    it "prefers an account-level override over the SiteSetting global" do
      SiteSetting.set(described_class::TTL_SETTING_KEY, "3600", setting_type: "integer")
      allow(account).to receive(:settings).and_return({ described_class::TTL_SETTING_KEY => "120" })
      expect(described_class.default_ttl_seconds(account: account)).to eq(120)
    end

    it "does not raise when SiteSetting lookup itself errors" do
      allow(SiteSetting).to receive(:get).and_raise(StandardError, "db down")
      expect(described_class.default_ttl_seconds(account: account)).to eq(described_class::DEFAULT_TTL_SECONDS)
    end
  end

  describe ".gc_expired!" do
    context "when a network has no expiry marked" do
      it "never archives it, regardless of age" do
        network.update!(created_at: 2.years.ago)

        result = described_class.gc_expired!(account: account)

        expect(network.reload.status).not_to eq("archived")
        expect(result[:archived]).to be_empty
      end
    end

    context "when a network's expiry hasn't passed yet" do
      it "leaves it alone" do
        described_class.mark_for_gc!(network, ttl_seconds: 1.day.to_i)

        result = described_class.gc_expired!(account: account)

        expect(network.reload.status).not_to eq("archived")
        expect(result[:archived]).to be_empty
      end
    end

    context "when a network is expired and empty (no peers)" do
      it "archives it" do
        described_class.mark_for_gc!(network, ttl_seconds: -1)

        result = described_class.gc_expired!(account: account)

        expect(network.reload.status).to eq("archived")
        expect(result[:archived]).to eq([ network.id ])
      end
    end

    context "when a network is expired but has ANY peer (even a dead one)" do
      it "never archives it — peer presence always wins over expiry" do
        instance = create(:system_node_instance, account: account, status: "terminated")
        create(:sdwan_peer, account: account, network: network, node_instance: instance)
        described_class.mark_for_gc!(network, ttl_seconds: -1)

        result = described_class.gc_expired!(account: account)

        expect(network.reload.status).not_to eq("archived")
        expect(result[:skipped_has_peers]).to eq([ network.id ])
      end
    end

    it "does not re-archive an already-archived network" do
      described_class.mark_for_gc!(network, ttl_seconds: -1)
      network.update!(status: "archived")

      result = described_class.gc_expired!(account: account)

      expect(result[:archived]).to be_empty
    end

    it "tolerates a malformed expires_at value instead of raising" do
      network.update!(metadata: { "expires_at" => "not-a-real-timestamp" })

      expect { described_class.gc_expired!(account: account) }.not_to raise_error
      expect(network.reload.status).not_to eq("archived")
    end

    it "scopes to the given account when provided" do
      other_account = create(:account)
      other_network = create(:sdwan_network, account: other_account)
      described_class.mark_for_gc!(network, ttl_seconds: -1)
      described_class.mark_for_gc!(other_network, ttl_seconds: -1)

      described_class.gc_expired!(account: account)

      expect(network.reload.status).to eq("archived")
      expect(other_network.reload.status).not_to eq("archived")
    end

    it "sweeps across all accounts when none is given" do
      other_account = create(:account)
      other_network = create(:sdwan_network, account: other_account)
      described_class.mark_for_gc!(network, ttl_seconds: -1)
      described_class.mark_for_gc!(other_network, ttl_seconds: -1)

      result = described_class.gc_expired!

      expect(result[:archived]).to contain_exactly(network.id, other_network.id)
    end
  end
end
