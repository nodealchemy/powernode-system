# frozen_string_literal: true

require "rails_helper"

# IMP-f5b4cb4eeb20 — System::ProvisionLabelResolver is the extension-side seam registered as
# Powernode::ExtensionRegistry.provider(:provision_label_resolver). Core's PlanSnapshotService
# resolves provision-step display labels through it WITHOUT naming System::. These examples pin the
# resolution + account-scoping, and the region_code fix (the prior core impl called `region.code`,
# which raised NoMethodError and was swallowed by the rescue — so every non-local_qemu region
# silently rendered as nil).
RSpec.describe System::ProvisionLabelResolver do
  let(:account) { create(:account) }

  describe ".instance_label" do
    it "returns the instance type's name for an account-scoped id" do
      it_type = create(:system_provider_instance_type, account: account)
      result = described_class.instance_label(account: account, inputs: { "provider_instance_type_id" => it_type.id })
      expect(result).to eq(it_type.name)
    end

    it "returns nil for a blank, unknown, or cross-account id" do
      expect(described_class.instance_label(account: account, inputs: {})).to be_nil
      expect(described_class.instance_label(account: account, inputs: { "provider_instance_type_id" => SecureRandom.uuid })).to be_nil
      foreign = create(:system_provider_instance_type, account: create(:account))
      expect(described_class.instance_label(account: account, inputs: { provider_instance_type_id: foreign.id })).to be_nil
    end
  end

  describe ".region_label" do
    it "returns the region_code for a normal provider region (regression: core called .code → nil)" do
      provider = create(:system_provider, account: account, provider_type: "aws")
      region = create(:system_provider_region, account: account, provider: provider, region_code: "us-west-2")
      result = described_class.region_label(account: account, inputs: { "provider_region_id" => region.id })
      expect(result).to eq("us-west-2")
    end

    it "labels a local_qemu region as 'local hypervisor' (region code is meaningless there)" do
      provider = create(:system_provider, account: account, provider_type: "local_qemu")
      region = create(:system_provider_region, account: account, provider: provider)
      result = described_class.region_label(account: account, inputs: { provider_region_id: region.id })
      expect(result).to eq("local hypervisor")
    end

    it "returns nil for a blank or unknown id" do
      expect(described_class.region_label(account: account, inputs: {})).to be_nil
      expect(described_class.region_label(account: account, inputs: { "provider_region_id" => SecureRandom.uuid })).to be_nil
    end
  end

  describe "registered as the core provision_label_resolver seam" do
    it "is what Powernode::ExtensionRegistry.provider(:provision_label_resolver) returns" do
      expect(Powernode::ExtensionRegistry.provider(:provision_label_resolver)).to eq(described_class)
    end
  end
end
