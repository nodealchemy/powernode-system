# frozen_string_literal: true

require "rails_helper"

# IMP-f1f96c292991 — the local-qemu dev/test Provider block is sample
# content, behind Powernode::SampleContentGate, default OFF. The catalog
# body (architectures/platforms/modules/templates, delegated to
# System::AccountBootstrapService.seed_templates_for) is covered by
# account_bootstrap_service_spec.rb; this spec covers only the provider
# block this file seeds directly.
RSpec.describe "node_module_catalog.rb sample-content gating" do
  def load_seed!
    silence_warnings { load Rails.root.join("../extensions/system/server/db/seeds/node_module_catalog.rb") }
  end

  let!(:account) { create(:account) }

  context "when sample content is disabled (default)" do
    it "does not create the local-qemu provider" do
      load_seed!
      expect(::System::Provider.where(account: account, provider_type: "local_qemu")).to be_none
    end
  end

  context "when sample content is enabled" do
    before { SiteSetting.set(Powernode::SampleContentGate::SETTING_KEY, "true", setting_type: "boolean") }

    it "creates the local-qemu provider, connection, region and instance types" do
      load_seed!
      provider = ::System::Provider.find_by(account: account, provider_type: "local_qemu", name: "local-qemu")
      expect(provider).to be_present
      expect(::System::ProviderConnection.where(account: account, provider: provider, name: "qemu-conn")).to be_one
      expect(::System::ProviderRegion.where(account: account, provider: provider, region_code: "local")).to be_one
      expect(::System::ProviderInstanceType.where(account: account, provider: provider,
                                                    instance_type_code: %w[qemu.small qemu.medium]).count).to eq(2)
    end

    it "is idempotent — running twice does not duplicate rows" do
      load_seed!
      load_seed!
      expect(::System::Provider.where(account: account, provider_type: "local_qemu").count).to eq(1)
    end
  end
end
