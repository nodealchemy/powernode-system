# frozen_string_literal: true

require "rails_helper"

# IMP-f1f96c292991 — idempotent removal of sample/demo content already
# seeded on an established install. DEFAULT DRY RUN; apply mode requires
# confirm: true. Skip-if-referenced is the safety property under test: a
# template with a real node, a module with a real assignment or remaining
# template reference, or a provider with real infrastructure must never be
# removed, even though its name matches the sample-content list.
RSpec.describe System::SampleContentRemovalService do
  let!(:account) { create(:account) }

  describe "#initialize" do
    it "defaults to dry_run: true" do
      expect(described_class.new.instance_variable_get(:@dry_run)).to be(true)
    end

    it "refuses apply mode without confirm: true" do
      expect { described_class.new(dry_run: false) }.to raise_error(ArgumentError, /confirm: true/)
    end

    it "allows apply mode with confirm: true" do
      expect { described_class.new(dry_run: false, confirm: true) }.not_to raise_error
    end
  end

  describe "#call (dry run — default)" do
    let!(:agent) { create(:ai_agent, account: account, name: "Customer Success Agent") }
    let!(:template) { create(:system_node_template, account: account, name: "web-apache") }
    let!(:node_module) { create(:system_node_module, account: account, name: "apache") }
    let!(:provider) { create(:system_provider, account: account, provider_type: "local_qemu", name: "local-qemu") }

    it "states the candidate count before acting, per category" do
      report = described_class.new.call
      expect(report.counted).to eq(agents: 1, templates: 1, modules: 1, providers: 1)
      expect(report.total_candidates).to eq(4)
    end

    it "classifies unreferenced rows as removable but performs zero writes" do
      report = described_class.new.call
      expect(report.dry_run).to be(true)
      expect(report.removed[:agents].map { |r| r[:id] }).to eq([ agent.id ])
      expect(report.removed[:templates].map { |r| r[:id] }).to eq([ template.id ])
      expect(report.removed[:modules].map { |r| r[:id] }).to eq([ node_module.id ])
      expect(report.removed[:providers].map { |r| r[:id] }).to eq([ provider.id ])

      # Zero writes: every row still exists.
      expect(Ai::Agent.exists?(agent.id)).to be(true)
      expect(System::NodeTemplate.exists?(template.id)).to be(true)
      expect(System::NodeModule.exists?(node_module.id)).to be(true)
      expect(System::Provider.exists?(provider.id)).to be(true)
    end
  end

  describe "skip-if-referenced" do
    it "skips a sample template with node_count > 0" do
      template = create(:system_node_template, account: account, name: "web-nginx")
      create(:system_node, account: account, node_template: template)

      report = described_class.new.call
      expect(report.removed[:templates]).to be_empty
      expect(report.skipped[:templates].first).to include(id: template.id)
      expect(report.skipped[:templates].first[:reason]).to match(/node_count=1/)
    end

    it "skips a sample module with a real (non-zero) assignment_count" do
      node_module = create(:system_node_module, account: account, name: "nginx")
      create(:system_node_module_assignment, node_module: node_module,
             node: create(:system_node, account: account))

      report = described_class.new.call
      expect(report.removed[:modules]).to be_empty
      expect(report.skipped[:modules].first).to include(id: node_module.id)
      expect(report.skipped[:modules].first[:reason]).to match(/assignment_count=1/)
    end

    # The concrete, live-verified case (2026-09-18): nodejs-runtime is
    # excluded from SAMPLE_MODULE_NAMES by name, but this proves the
    # DYNAMIC check — not just the exclusion list — would also have caught
    # it: any sample-named module referenced by a NON-sample template (one
    # not in this removal run, standing in for "powernode-ops-cell") is
    # skipped rather than removed.
    it "skips a sample module still referenced by a template NOT in this removal run" do
      node_module = create(:system_node_module, account: account, name: "apache")
      real_template = create(:system_node_template, account: account, name: "powernode-ops-cell")
      create(:system_template_module, node_template: real_template, node_module: node_module)

      report = described_class.new.call
      expect(report.removed[:modules]).to be_empty
      expect(report.skipped[:modules].first).to include(id: node_module.id)
      expect(report.skipped[:modules].first[:reason]).to match(/remaining_template_refs=1/)
    end

    it "removes a sample module whose ONLY reference is a sample template in the SAME run (dry-run agrees with apply)" do
      template = create(:system_node_template, account: account, name: "web-apache")
      node_module = create(:system_node_module, account: account, name: "apache")
      create(:system_template_module, node_template: template, node_module: node_module)

      dry = described_class.new.call
      expect(dry.removed[:modules].map { |r| r[:id] }).to eq([ node_module.id ])

      applied = described_class.new(dry_run: false, confirm: true).call
      expect(applied.removed[:modules].map { |r| r[:id] }).to eq([ node_module.id ])
      expect(System::NodeModule.exists?(node_module.id)).to be(false)
    end

    it "skips a sample agent with real conversations" do
      agent = create(:ai_agent, account: account, name: "Sales Operations Specialist")
      create(:ai_conversation, account: account, agent: agent)

      report = described_class.new.call
      expect(report.removed[:agents]).to be_empty
      expect(report.skipped[:agents].first).to include(id: agent.id)
    end

    it "skips a sample-typed provider with real node-instance infrastructure behind it" do
      provider = create(:system_provider, account: account, provider_type: "local_qemu", name: "local-qemu")
      region = create(:system_provider_region, account: account, provider: provider)
      create(:system_node_instance, account: account, provider_region: region)

      report = described_class.new.call
      expect(report.removed[:providers]).to be_empty
      expect(report.skipped[:providers].first).to include(id: provider.id)
    end
  end

  describe "#call (apply mode)" do
    let!(:agent) { create(:ai_agent, account: account, name: "Life Sciences Research Analyst") }
    let!(:template) { create(:system_node_template, account: account, name: "rpi4-base") }
    let!(:node_module) { create(:system_node_module, account: account, name: "rpi4-firmware") }
    let!(:provider) { create(:system_provider, account: account, provider_type: "local_qemu", name: "local-qemu") }

    it "actually destroys unreferenced candidate rows" do
      described_class.new(dry_run: false, confirm: true).call

      expect(Ai::Agent.exists?(agent.id)).to be(false)
      expect(System::NodeTemplate.exists?(template.id)).to be(false)
      expect(System::NodeModule.exists?(node_module.id)).to be(false)
      expect(System::Provider.exists?(provider.id)).to be(false)
    end

    it "is idempotent — a second apply run removes nothing and reports zero removals" do
      first = described_class.new(dry_run: false, confirm: true).call
      expect(first.total_removed).to eq(4)

      second = described_class.new(dry_run: false, confirm: true).call
      expect(second.total_removed).to eq(0)
      expect(second.counted).to eq(agents: 0, templates: 0, modules: 0, providers: 0)
    end

    it "never touches a skipped (referenced) row across repeated apply runs" do
      referenced_template = create(:system_node_template, account: account, name: "rpi4-hardened")
      create(:system_node, account: account, node_template: referenced_template)

      described_class.new(dry_run: false, confirm: true).call
      described_class.new(dry_run: false, confirm: true).call

      expect(System::NodeTemplate.exists?(referenced_template.id)).to be(true)
    end
  end
end
