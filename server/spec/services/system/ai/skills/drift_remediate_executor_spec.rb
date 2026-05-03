# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M6.A — DriftRemediateExecutor skill.
RSpec.describe System::Ai::Skills::DriftRemediateExecutor do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:instance) { create(:system_node_instance, :running, node: node) }
  let(:exec)     { described_class.new(account: account) }

  let(:mod) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription", name: "drift-mod")
  end
  let!(:version) do
    v = System::NodeModuleVersion.create!(
      node_module: mod, version_number: 1,
      mask: [], file_spec: [], package_spec: [], config: {},
      oci_digest: "sha256:#{'a' * 64}"
    )
    mod.update!(current_version_id: v.id)
    v
  end

  describe ".descriptor" do
    it "returns a complete skill descriptor" do
      d = described_class.descriptor
      expect(d[:name]).to eq("drift_remediate")
      expect(d[:category]).to eq("devops")
      expect(d.dig(:inputs, :instance_id, :required)).to be true
      expect(d.dig(:outputs)).to include(:resolved, :requires_approval, :disruption_pct, :planned_actions)
    end
  end

  describe "#execute" do
    context "with no drift" do
      before do
        System::NodeModuleAssignment.create!(node: node, node_module: mod, enabled: true, priority: 0)
        instance.update!(running_module_digests: { mod.id => "sha256:#{'a' * 64}" })
      end

      it "returns resolved=true with empty planned_actions" do
        r = exec.execute(instance_id: instance.id)
        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:resolved]).to be true
        expect(d[:requires_approval]).to be false
        expect(d[:disruption_pct]).to eq(0)
        expect(d[:planned_actions]).to eq(attach: [], detach: [], update: [])
        expect(d[:reason]).to eq("no drift")
      end
    end

    context "with one missing module" do
      before do
        System::NodeModuleAssignment.create!(node: node, node_module: mod, enabled: true, priority: 0)
        instance.update!(running_module_digests: {}) # nothing running
      end

      it "plans an attach + reports modest disruption" do
        r = exec.execute(instance_id: instance.id)
        expect(r[:data][:resolved]).to be true # below default 20% threshold
        expect(r[:data][:requires_approval]).to be false
        expect(r[:data][:disruption_pct]).to eq(20)
        expect(r[:data][:planned_actions][:attach]).to eq([ mod.id ])
      end
    end

    context "with many drifted modules" do
      let(:mods) do
        Array.new(3) do |i|
          create(:system_node_module, account: account, node_platform: platform,
                 category: category, variety: "subscription", name: "many-mod-#{i}")
        end
      end

      before do
        mods.each_with_index do |m, i|
          v = System::NodeModuleVersion.create!(
            node_module: m, version_number: 1,
            mask: [], file_spec: [], package_spec: [], config: {},
            oci_digest: "sha256:#{'b' * 60}#{i.to_s.rjust(4, '0')}"
          )
          m.update!(current_version_id: v.id)
          System::NodeModuleAssignment.create!(node: node, node_module: m, enabled: true, priority: 0)
        end
        instance.update!(running_module_digests: {})
      end

      it "exceeds default threshold and flags requires_approval=true" do
        r = exec.execute(instance_id: instance.id)
        expect(r[:data][:disruption_pct]).to be >= 60
        expect(r[:data][:requires_approval]).to be true
        expect(r[:data][:resolved]).to be false
        expect(r[:data][:planned_actions][:attach].size).to eq(3)
      end

      it "honors custom max_disruption_pct" do
        r = exec.execute(instance_id: instance.id, max_disruption_pct: 80)
        expect(r[:data][:requires_approval]).to be false
        expect(r[:data][:resolved]).to be true
      end
    end

    context "when drift_report fails (instance not found)" do
      it "returns failure result" do
        r = exec.execute(instance_id: SecureRandom.uuid)
        expect(r[:success]).to be false
        expect(r[:error]).to match(/drift_report failed/)
      end
    end

    context "with extra running modules + mismatched digest" do
      let(:other_mod) do
        create(:system_node_module, account: account, node_platform: platform,
               category: category, variety: "subscription", name: "extra-mod")
      end

      before do
        System::NodeModuleAssignment.create!(node: node, node_module: mod, enabled: true, priority: 0)
        instance.update!(running_module_digests: {
          mod.id => "sha256:#{'c' * 64}",       # mismatch
          other_mod.id => "sha256:#{'d' * 64}"  # extra
        })
      end

      it "produces a plan with update + detach entries" do
        r = exec.execute(instance_id: instance.id)
        actions = r[:data][:planned_actions]
        expect(actions[:update]).to include(mod.id)
        expect(actions[:detach]).to include(other_mod.id)
      end
    end
  end
end
