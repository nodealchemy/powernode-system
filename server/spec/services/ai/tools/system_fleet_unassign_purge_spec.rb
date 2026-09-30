# frozen_string_literal: true

require "rails_helper"

# IMP-5fa3c8d0e2f7 — system_unassign_module_from_template destroyed the
# TemplateModule join and nothing else. The FK nullified
# source_template_module_id on every NodeModuleAssignment the join had
# produced, TemplateApplyService's purge_stale skips a NULL source, and so the
# nodes kept a module the template had dropped with nothing left that would
# ever reap it. The verb now purges the derived rows in the same transaction
# (System::TemplateModuleUnassignService, shared with the REST DELETE) and
# reports what it purged.
RSpec.describe Ai::Tools::SystemFleetTool, "unassigning a module from a template purges its derived assignments" do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account, name: "cat-#{SecureRandom.hex(3)}") }
  let(:template) do
    create(:system_node_template, account: account, node_platform: platform, name: "tmpl-#{SecureRandom.hex(3)}")
  end
  let(:tool) { described_class.new(account: account, internal: true) }

  def call(action, **rest)
    tool.execute(params: { action: action }.merge(rest))
  end

  def node_module(name)
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription", name: "#{name}-#{SecureRandom.hex(3)}")
  end

  def node!
    create(:system_node, account: account, node_template: template, name: "node-#{SecureRandom.hex(3)}")
  end

  def events
    System::FleetEvent.where(account: account, kind: "system.template_mutation")
  end

  let(:removed_mod) { node_module("removed") }
  let(:kept_mod)    { node_module("kept") }
  let(:hand_mod)    { node_module("hand") }
  let!(:removed_join) { ::System::TemplateModule.create!(node_template: template, node_module: removed_mod) }
  let!(:kept_join)    { ::System::TemplateModule.create!(node_template: template, node_module: kept_mod) }
  let(:node_a) { node! }
  let(:node_b) { node! }

  before do
    [ node_a, node_b ].each { |n| System::TemplateApplyService.new(n).apply! }
    create(:system_node_module_assignment, node: node_a, node_module: hand_mod)
  end

  def unassign
    call("system_unassign_module_from_template", template_id: template.id, module_id: removed_mod.id)
  end

  it "leaves no assignment derived from the join — none orphaned to a NULL source" do
    result = unassign

    expect(result[:success]).to be true
    expect(System::NodeModuleAssignment.where(node_module_id: removed_mod.id)).to be_empty
  end

  it "leaves hand-authored rows and another join's rows untouched" do
    unassign

    expect(node_a.node_module_assignments.find_by!(node_module_id: hand_mod.id).source_template_module_id).to be_nil
    expect(System::NodeModuleAssignment.where(node_module_id: kept_mod.id).pluck(:source_template_module_id))
      .to contain_exactly(kept_join.id, kept_join.id)
  end

  it "reports the purged node ids and count" do
    data = unassign[:data]

    expect(data[:unassigned]).to be true
    expect(data.dig(:purged_assignments, :count)).to eq(2)
    expect(data.dig(:purged_assignments, :node_ids)).to contain_exactly(node_a.id, node_b.id)
  end

  it "stays idempotent when the join is already gone" do
    removed_join.destroy!

    data = unassign[:data]

    expect(data[:already_absent]).to be true
    expect(data).not_to have_key(:purged_assignments)
  end

  context "when the template carries live fleet" do
    before { create(:system_node_instance, :running, node: node_a) }

    it "states the purge count and node ids in blast_radius and in the FleetEvent" do
      result = nil
      expect { result = unassign }.to change { events.count }.by(1)

      radius = result.dig(:data, :blast_radius)
      expect(radius[:provisioned_node_count]).to eq(1)
      expect(radius[:purged_assignment_count]).to eq(2)
      expect(radius[:purged_node_ids]).to contain_exactly(node_a.id, node_b.id)

      payload = events.order(:created_at).last.payload
      expect(payload["change"]).to eq("module_unassigned")
      expect(payload["purged_assignment_count"]).to eq(2)
    end

    # Disabling a join keeps its derived rows (the next purging apply reaps
    # them). Unassigning it now reaps them at once, which takes the module off
    # live nodes — a blast radius the old `shipped`-only rule would have hidden.
    it "reports blast_radius for a DISABLED join whose derived rows it purges" do
      removed_join.update!(enabled: false)

      result = nil
      expect { result = unassign }.to change { events.count }.by(1)

      expect(result.dig(:data, :blast_radius, :purged_assignment_count)).to eq(2)
    end
  end
end
