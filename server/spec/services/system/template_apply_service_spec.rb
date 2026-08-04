# frozen_string_literal: true

require "rails_helper"

# The whole-set half of the composition invariant.
#
# Every write-path guard is a DELTA — deliberately, so a template that already
# composes badly stays editable. That leaves a gap the deltas cannot close on
# their own: anything landed before the guards existed, or through a path that
# only warns (clone/import), is permanent baseline that later deltas are then
# obliged to treat as acceptable. Template apply is where such a baseline stops
# being a database row and starts becoming NodeModuleAssignments on a real
# node, so it is where the whole set is judged.
#
# It WARNS rather than refuses: apply! is on the provisioning critical path
# (ProvisioningService, FulfillmentAdvanceOrchestrator) and on the autonomous
# drift-remediation path (Fleet::DecisionEngine), so failing closed would turn
# one poisoned template into a provisioning outage for every node on it —
# while the conflict itself is fatal at BUILD time, not at assignment
# materialization. Refusing here would remove the signal without preventing
# the damage.
RSpec.describe System::TemplateApplyService, "whole-set composition check" do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account, name: "cat-#{SecureRandom.hex(3)}") }
  let(:template) do
    create(:system_node_template, account: account, node_platform: platform,
           name: "tmpl-#{SecureRandom.hex(3)}")
  end
  let(:node) do
    create(:system_node, account: account, node_template: template, name: "node-#{SecureRandom.hex(3)}")
  end

  def node_module(name, variety: "subscription")
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: variety, name: "#{name}-#{SecureRandom.hex(3)}")
  end

  def assign(mod, enabled: true)
    ::System::TemplateModule.create!(node_template: template, node_module: mod, enabled: enabled)
  end

  context "on a template whose baseline is poisoned" do
    let!(:first)  { assign(node_module("inst-a", variety: "instance")).node_module }
    let!(:second) { assign(node_module("inst-b", variety: "instance")).node_module }

    it "still applies — refusing would take the provisioning path down with it" do
      result = described_class.new(node).apply!

      expect(result).to be_ok
      expect(result.created.size).to eq(2)
    end

    it "surfaces the conflict in the apply warnings, naming the modules" do
      result = described_class.new(node).apply!

      expect(result.warnings.join(" ")).to include("instance_variety_collision")
        .and include(first.name).and include(second.name)
    end

    it "surfaces it on the dry-run preview too, before anything is written" do
      result = described_class.new(node).apply!(dry_run: true)

      expect(result.warnings.join(" ")).to include("instance_variety_collision")
      expect(node.node_module_assignments.count).to eq(0)
    end
  end

  it "warns about nothing for a template that composes" do
    assign(node_module("clean-a"))
    assign(node_module("clean-b"))

    result = described_class.new(node).apply!

    expect(result).to be_ok
    expect(result.warnings.join(" ")).not_to include("instance_variety_collision")
  end

  it "ignores disabled joins — a module that doesn't ship can't collide" do
    assign(node_module("live-inst", variety: "instance"))
    assign(node_module("dark-inst", variety: "instance"), enabled: false)

    result = described_class.new(node).apply!

    expect(result.warnings.join(" ")).not_to include("instance_variety_collision")
  end

  # Only error-severity conflicts reach the warnings — protected_spec overlap
  # is auto-resolved by the build pipeline, and apply! runs on every
  # provisioning and every drift tick, so it must not become a noise source.
  it "does not report warning-severity overlaps at apply time" do
    claimer = node_module("claimer")
    claimer.update!(protected_spec: "/etc/shadow")
    assign(claimer)
    broad = node_module("broad")
    broad.update!(file_spec: "/etc/**")
    assign(broad)

    result = described_class.new(node).apply!

    expect(result.warnings.join(" ")).not_to include("protected_spec_overlap")
  end
end
