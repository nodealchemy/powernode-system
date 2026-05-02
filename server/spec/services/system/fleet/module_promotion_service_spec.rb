# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M7.C — ModulePromotionService.
RSpec.describe System::Fleet::ModulePromotionService do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:mod) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription", name: "promo-mod")
  end
  let!(:version) do
    System::NodeModuleVersion.create!(
      node_module: mod, version_number: 1,
      mask: [], file_spec: [], package_spec: [], config: {},
      oci_digest: "sha256:#{'a' * 64}",
      promotion_state: "staging"
    )
  end

  describe ".promote!" do
    it "rejects staging→blessed when criteria not met" do
      result = described_class.promote!(version: version, target_state: "blessed")
      expect(result.ok?).to be false
      expect(result.error).to match(/not eligible/)
    end

    it "allows staging→retired (operator-driven decommission, no criteria)" do
      result = described_class.promote!(version: version, target_state: "retired")
      expect(result.ok?).to be true
      expect(version.reload.promotion_state).to eq("retired")
    end

    it "rejects an invalid transition" do
      result = described_class.promote!(version: version, target_state: "live")
      expect(result.ok?).to be false
      expect(result.error).to match(/cannot transition|InvalidTransition/i)
    end
  end
end
