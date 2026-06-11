# frozen_string_literal: true

require "rails_helper"

# Audit F4-06 — providers passed registry checks but raised
# NotImplementedError at runtime mid-mission, and nothing could discover
# support before dispatching. These specs pin the capability-discovery
# surface and the providers that previously inherited-and-raised.
RSpec.describe "Provider capability discovery (F4-06)" do
  # BaseProvider#initialize dereferences connection.provider when no region
  # is given — pass a region stand-in; capability checks touch neither.
  def adapter_for(klass)
    klass.new(nil, region: :capability_check_only)
  end

  describe System::Providers::BaseProvider do
    it "declares the full capability set by default" do
      expect(described_class::CAPABILITIES).to match_array(%i[instances volumes ips images sync])
    end
  end

  describe System::Providers::LocalQemuProvider do
    it "declares instances + sync only (no volume/ip/image surface)" do
      adapter = adapter_for(described_class)
      expect(adapter.capabilities).to match_array(%i[instances sync])
      expect(adapter.supports?(:instances)).to be true
      expect(adapter.supports?(:volumes)).to be false
      expect(adapter.supports?(:ips)).to be false
      expect(adapter.supports?(:images)).to be false
    end
  end

  describe System::Providers::ProCloudProvider do
    it "declares instance lifecycle only" do
      expect(adapter_for(described_class).capabilities).to match_array(%i[instances])
    end

    it "implements authenticate? via the connection test instead of raising" do
      adapter = adapter_for(described_class)
      allow(adapter).to receive(:test_connection).and_return({ success: true })
      expect(adapter.authenticate?).to be true

      allow(adapter).to receive(:test_connection).and_return({ success: false, error: "bad key" })
      expect(adapter.authenticate?).to be false
    end

    it "structurally declines list_instances instead of raising" do
      result = adapter_for(described_class).list_instances
      expect(result[:success]).to be false
      expect(result[:error]).to match(/does not support/i)
      expect(result[:instances]).to eq([])
    end
  end

  describe System::Providers::MockProvider do
    it "implements authenticate? instead of raising" do
      expect(adapter_for(described_class).authenticate?).to be true
    end
  end

  describe System::Providers::ProxmoxProvider do
    it "excludes :ips, matching its structurally-declined IP operations" do
      expect(adapter_for(described_class).supports?(:ips)).to be false
    end
  end
end
