# frozen_string_literal: true

require "rails_helper"

# Audit finding F4-03: allocate_ip/release_ip called Registry.for_node(nil,
# region:) which dereferenced nil.account and raised NoMethodError on every
# invocation — the standalone elastic-IP capability had never worked. The fix
# resolves the adapter from (region, account) like VolumeManagementService;
# these specs pin that lookup path so it cannot regress.
RSpec.describe System::IpManagementService do
  let(:account)    { create(:account) }
  let(:region)     { create(:system_provider_region) }
  let(:connection) { double("provider connection") }
  let(:adapter)    { instance_double("System::Providers::BaseProvider") }

  before do
    allow(System::Providers::Registry).to receive(:find_connection_for_region)
      .with(region, account).and_return(connection)
    allow(System::Providers::Registry).to receive(:for)
      .with(connection, region: region).and_return(adapter)
    allow(adapter).to receive(:supports?).and_return(true)
  end

  describe ".allocate_ip" do
    it "allocates via the adapter resolved from region + account" do
      allow(adapter).to receive(:allocate_ip)
        .and_return({ success: true, allocation_id: "eip-1", public_ip: "203.0.113.9" })

      result = described_class.allocate_ip(region: region, account: account)

      expect(result[:success]).to be(true)
      expect(result[:allocation_id]).to eq("eip-1")
      expect(result[:public_ip]).to eq("203.0.113.9")
    end

    # Audit F4-06 — local_qemu has no IP surface; the capability gate must
    # refuse structurally instead of letting NotImplementedError propagate.
    it "returns a structured error when the provider lacks IP support" do
      allow(adapter).to receive(:supports?).with(:ips).and_return(false)
      allow(adapter).to receive(:provider_type).and_return("local_qemu")
      allow(adapter).to receive(:allocate_ip)

      result = described_class.allocate_ip(region: region, account: account)

      expect(result[:success]).to be(false)
      expect(result[:error]).to match(/does not support IP/i)
      expect(adapter).not_to have_received(:allocate_ip)
    end

    it "returns an error result when no provider connection covers the region" do
      allow(System::Providers::Registry).to receive(:find_connection_for_region)
        .with(region, account).and_return(nil)

      result = described_class.allocate_ip(region: region, account: account)

      expect(result[:success]).to be(false)
      expect(result[:error]).to match(/No provider connection/)
    end

    it "returns an error result on provider failure" do
      allow(adapter).to receive(:allocate_ip)
        .and_return({ success: false, error: "quota exceeded" })

      result = described_class.allocate_ip(region: region, account: account)

      expect(result[:success]).to be(false)
      expect(result[:error]).to eq("quota exceeded")
    end
  end

  describe ".release_ip" do
    it "releases via the adapter resolved from region + account" do
      allow(adapter).to receive(:release_ip).with("eip-1").and_return({ success: true })

      result = described_class.release_ip(region: region, account: account, allocation_id: "eip-1")

      expect(result[:success]).to be(true)
    end

    it "returns an error result when no provider connection covers the region" do
      allow(System::Providers::Registry).to receive(:find_connection_for_region)
        .with(region, account).and_return(nil)

      result = described_class.release_ip(region: region, account: account, allocation_id: "eip-1")

      expect(result[:success]).to be(false)
      expect(result[:error]).to match(/No provider connection/)
    end
  end
end
