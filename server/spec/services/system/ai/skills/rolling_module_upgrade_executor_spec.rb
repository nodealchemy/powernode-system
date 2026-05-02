# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M6.C — RollingModuleUpgradeExecutor skill.
RSpec.describe System::Ai::Skills::RollingModuleUpgradeExecutor do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }

  let(:mod) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription", name: "rolling-mod")
  end
  let!(:target_version) do
    System::NodeModuleVersion.create!(
      node_module: mod, version_number: 2,
      mask: [], file_spec: [], package_spec: [], config: {},
      oci_digest: "sha256:#{'a' * 64}"
    )
  end

  let(:exec) { described_class.new(account: account) }

  describe ".descriptor" do
    it "advertises required inputs" do
      d = described_class.descriptor
      expect(d[:name]).to eq("rolling_module_upgrade")
      expect(d.dig(:inputs, :template_id, :required)).to be true
      expect(d.dig(:inputs, :module_id, :required)).to be true
      expect(d.dig(:inputs, :target_version_id, :required)).to be true
    end
  end

  describe "#execute" do
    context "with no eligible instances" do
      it "returns an empty plan with note" do
        r = exec.execute(template_id: template.id, module_id: mod.id, target_version_id: target_version.id)
        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:total_instances]).to eq(0)
        expect(d[:batches]).to be_empty
        expect(d[:note]).to match(/nothing to do/)
      end
    end

    context "with running instances" do
      before do
        5.times do |i|
          node = create(:system_node, account: account, node_template: template, name: "n-#{i}")
          create(:system_node_instance, :running, node: node)
        end
      end

      it "splits into ceiling-rounded batches at default 10%" do
        r = exec.execute(template_id: template.id, module_id: mod.id, target_version_id: target_version.id)
        d = r[:data]
        expect(d[:total_instances]).to eq(5)
        expect(d[:batch_size]).to eq(1) # ceil(5 * 0.10) = 1
        expect(d[:batch_count]).to eq(5)
        expect(d[:requires_approval]).to be true
        expect(d[:target][:target_version_id]).to eq(target_version.id)
      end

      it "honors custom batch_pct" do
        r = exec.execute(template_id: template.id, module_id: mod.id, target_version_id: target_version.id, batch_pct: 50)
        d = r[:data]
        expect(d[:batch_size]).to eq(3) # ceil(5 * 0.50) = 3
        expect(d[:batch_count]).to eq(2) # 3 + 2
      end

      it "produces ETA estimates per batch" do
        r = exec.execute(template_id: template.id, module_id: mod.id, target_version_id: target_version.id, batch_pct: 100)
        d = r[:data]
        expect(d[:batch_count]).to eq(1)
        expect(d[:estimated_total_seconds]).to eq(5 * 120)
      end

      it "rejects out-of-range batch_pct" do
        r = exec.execute(template_id: template.id, module_id: mod.id, target_version_id: target_version.id, batch_pct: 150)
        expect(r[:success]).to be false
        expect(r[:error]).to match(/batch_pct must be/)
      end
    end

    context "when target_version_id does not belong to module" do
      let!(:other_mod) { create(:system_node_module, account: account, node_platform: platform, category: category, variety: "subscription", name: "other-mod") }
      let!(:other_version) { System::NodeModuleVersion.create!(node_module: other_mod, version_number: 1, mask: [], file_spec: [], package_spec: [], config: {}, oci_digest: "sha256:#{'b' * 64}") }

      it "returns a clear failure" do
        r = exec.execute(template_id: template.id, module_id: mod.id, target_version_id: other_version.id)
        expect(r[:success]).to be false
        expect(r[:error]).to match(/target_version_id not found/)
      end
    end
  end
end
