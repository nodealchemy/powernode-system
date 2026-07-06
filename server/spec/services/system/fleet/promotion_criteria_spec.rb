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

  # Configurable thresholds — a 1-2 instance fleet can never reach the
  # baked-in REQUIRED_COUNT of 3, so staging→blessed is unreachable until
  # the operator can tune the bar. Resolution cascade (highest wins):
  # per-module config → per-account settings → SiteSetting global → default.
  describe "configurable thresholds" do
    def make_running_instance(idx, heartbeat_at:)
      node = create(:system_node, account: account, node_template: template, name: "cfg-node-#{idx}")
      node.node_modules << mod
      create(:system_node_instance, :running, node: node).tap do |inst|
        inst.update!(running_module_digests: { mod.id => digest }, last_heartbeat_at: heartbeat_at)
      end
    end

    context "with a per-account required_count override lowering the bar to 1" do
      before do
        account.update!(settings: { "module_promotion_required_count" => 1 })
        make_running_instance(0, heartbeat_at: (described_class::DWELL_TIME + 5.minutes).ago)
      end

      it "promotes a single-instance fleet" do
        result = described_class.evaluate(version: version)
        expect(result[:eligible]).to be true
        expect(result[:running_count]).to eq(1)
        expect(result[:required_count]).to eq(1)
      end
    end

    context "with a per-account dwell override of 0 minutes" do
      before do
        account.update!(settings: { "module_promotion_dwell_minutes" => 0 })
        described_class::REQUIRED_COUNT.times { |i| make_running_instance(i, heartbeat_at: 1.minute.ago) }
      end

      it "does not require any dwell time" do
        result = described_class.evaluate(version: version)
        expect(result[:eligible]).to be true
      end
    end

    context "with a per-module config override taking precedence over the account setting" do
      before do
        account.update!(settings: { "module_promotion_required_count" => 5 })
        mod.update!(config: { "module_promotion_required_count" => 1 })
        make_running_instance(0, heartbeat_at: (described_class::DWELL_TIME + 5.minutes).ago)
      end

      it "uses the module override" do
        result = described_class.evaluate(version: version)
        expect(result[:eligible]).to be true
        expect(result[:required_count]).to eq(1)
      end
    end

    context "with a SiteSetting global override and no per-account/per-module value" do
      before do
        SiteSetting.set("module_promotion_required_count", 1, setting_type: "integer")
        make_running_instance(0, heartbeat_at: (described_class::DWELL_TIME + 5.minutes).ago)
      end

      it "falls back to the global default" do
        result = described_class.evaluate(version: version)
        expect(result[:eligible]).to be true
        expect(result[:required_count]).to eq(1)
      end
    end

    context "with a required_count override of 0 (below the floor)" do
      before do
        account.update!(settings: { "module_promotion_required_count" => 0 })
        make_running_instance(0, heartbeat_at: (described_class::DWELL_TIME + 5.minutes).ago)
      end

      it "clamps to a minimum of 1" do
        result = described_class.evaluate(version: version)
        expect(result[:eligible]).to be true
        expect(result[:required_count]).to eq(1)
      end
    end

    context "with no overrides configured" do
      it "preserves the baked-in defaults" do
        expect(described_class::REQUIRED_COUNT).to eq(3)
        expect(described_class::DWELL_TIME).to eq(30.minutes)

        described_class::REQUIRED_COUNT.times { |i| make_running_instance(i, heartbeat_at: (described_class::DWELL_TIME + 5.minutes).ago) }
        result = described_class.evaluate(version: version)
        expect(result[:eligible]).to be true
        expect(result[:required_count]).to eq(3)
      end
    end
  end
end
