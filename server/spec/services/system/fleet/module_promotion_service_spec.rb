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

  # IMP-bdb650b82c65 — the gated target-state set has ONE definition,
  # PromotionCriteria::GATED_TARGET_STATES. This service used to carry its own
  # `target_state == "blessed"` literal beside it; the two agreed by
  # coincidence, and the equality oracle in manual_promotion_advisory_spec.rb
  # only proves they agree TODAY. This drives the seam the other way: widen
  # the shared set and the service must refuse on the new state without an
  # edit here. blessed→live is a legal transition the criteria do not gate
  # today, so it is exactly the case a private literal keeps passing.
  describe "the gated target-state set" do
    let!(:blessed_version) do
      System::NodeModuleVersion.create!(
        node_module: mod, version_number: 2,
        mask: [], file_spec: [], package_spec: [], config: {},
        oci_digest: "sha256:#{'c' * 64}",
        promotion_state: "blessed"
      )
    end

    it "follows PromotionCriteria::GATED_TARGET_STATES rather than a literal of its own" do
      # Sanity: ungated today, so the transition goes through on no evidence.
      expect(System::Fleet::PromotionCriteria.gates?("live")).to be false

      stub_const("System::Fleet::PromotionCriteria::GATED_TARGET_STATES", %w[blessed live])
      expect(System::Fleet::PromotionCriteria.gates?("live")).to be true

      result = described_class.promote!(version: blessed_version, target_state: "live")

      expect(result.ok?).to be false
      expect(result.error).to match(/not eligible/)
      expect(blessed_version.reload.promotion_state).to eq("blessed")
    end

    it "carries no target-state literal in the source" do
      src = File.read(File.expand_path(
        "../../../../app/services/system/fleet/module_promotion_service.rb", __dir__
      ))
      expect(src).not_to match(/target_state\s*==\s*["']/)
      expect(src).to include("PromotionCriteria.gates?(")
    end
  end
end
