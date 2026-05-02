# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M7.C — PromotionCriteria.
RSpec.describe System::Fleet::PromotionCriteria do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:mod) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription", name: "promo-mod")
  end
  let(:digest) { "sha256:#{'a' * 64}" }

  let!(:version) do
    System::NodeModuleVersion.create!(
      node_module: mod, version_number: 1,
      mask: [], file_spec: [], package_spec: [], config: {},
      oci_digest: digest,
      promotion_state: "staging"
    )
  end

  describe ".evaluate" do
    context "with no oci_digest" do
      it "returns ineligible" do
        version.update!(oci_digest: nil)
        result = described_class.evaluate(version: version)
        expect(result[:eligible]).to be false
        expect(result[:reason]).to match(/no oci_digest/)
      end
    end

    context "with fewer than REQUIRED_COUNT instances running the digest" do
      it "returns ineligible with running_count" do
        result = described_class.evaluate(version: version)
        expect(result[:eligible]).to be false
        expect(result[:running_count]).to eq(0)
        expect(result[:required_count]).to eq(described_class::REQUIRED_COUNT)
      end
    end

    context "with REQUIRED_COUNT instances at sufficient dwell time" do
      before do
        described_class::REQUIRED_COUNT.times do |i|
          node = create(:system_node, account: account, node_template: template, name: "promo-node-#{i}")
          node.node_modules << mod
          inst = create(:system_node_instance, :running, node: node)
          inst.update!(
            running_module_digests: { mod.id => digest },
            last_heartbeat_at: (described_class::DWELL_TIME + 5.minutes).ago
          )
        end
      end

      it "returns eligible" do
        result = described_class.evaluate(version: version)
        expect(result[:eligible]).to be true
        expect(result[:running_count]).to eq(described_class::REQUIRED_COUNT)
        expect(result[:dwell_time_minutes]).to be > (described_class::DWELL_TIME / 60).to_i
      end
    end
  end
end
