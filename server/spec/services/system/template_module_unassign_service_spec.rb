# frozen_string_literal: true

require "rails_helper"

# IMP-5fa3c8d0e2f7 — unassigning a module from a template orphaned the node
# assignments the template had produced.
#
# Destroying a TemplateModule join fires the FK's ON DELETE SET NULL on
# system_node_module_assignments.source_template_module_id, and
# TemplateApplyService's purge_stale skips every row whose source is NULL (that
# is how it recognises a hand-authored row). So the derived rows became
# indistinguishable from hand-authored ones and nothing would ever reap them:
# the node kept a module its template had dropped, forever.
#
# The fix removes the derived rows in the same transaction as the join. It is
# closure-aware: a derived row whose module is STILL in the node's template
# closure through another join (a transitive dependency another join also
# requires, attributed to the removed join by the expansion's nearest-ancestor
# tie-break) is re-pointed to that join instead of destroyed, because
# destroying it would strip a module the template still needs.
RSpec.describe System::TemplateModuleUnassignService do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account, name: "cat-#{SecureRandom.hex(3)}") }
  let(:template) do
    create(:system_node_template, account: account, node_platform: platform, name: "tmpl-#{SecureRandom.hex(3)}")
  end

  def node_module(name)
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription", name: "#{name}-#{SecureRandom.hex(3)}")
  end

  def join!(mod, priority: 50, enabled: true)
    ::System::TemplateModule.create!(node_template: template, node_module: mod, priority: priority, enabled: enabled)
  end

  def node!(name = "node")
    create(:system_node, account: account, node_template: template, name: "#{name}-#{SecureRandom.hex(3)}")
  end

  let(:removed_mod) { node_module("removed") }
  let(:kept_mod)    { node_module("kept") }
  let(:hand_mod)    { node_module("hand") }
  let!(:removed_join) { join!(removed_mod) }
  let!(:kept_join)    { join!(kept_mod) }
  let(:node_a) { node! }
  let(:node_b) { node! }

  before do
    [ node_a, node_b ].each { |n| System::TemplateApplyService.new(n).apply! }
    # Hand-authored: NULL source, never reaped by template reconciliation.
    create(:system_node_module_assignment, node: node_a, node_module: hand_mod)
  end

  def unassign!
    described_class.new(removed_join).call!(initiated_by: nil, source: "spec")
  end

  def derived_rows
    System::NodeModuleAssignment.where(source_template_module_id: removed_join.id)
  end

  it "destroys every assignment derived from the join, and the join, leaving no orphan" do
    expect(derived_rows.count).to eq(2)

    unassign!

    expect(System::TemplateModule.exists?(removed_join.id)).to be false
    expect(System::NodeModuleAssignment.where(node_module_id: removed_mod.id)).to be_empty
  end

  it "leaves hand-authored rows and rows derived from another join untouched" do
    hand = node_a.node_module_assignments.find_by!(node_module_id: hand_mod.id)
    kept = System::NodeModuleAssignment.where(source_template_module_id: kept_join.id).to_a

    unassign!

    expect(hand.reload.source_template_module_id).to be_nil
    expect(kept.map { |a| a.reload.source_template_module_id }).to all(eq(kept_join.id))
  end

  it "reports the purged node ids and count" do
    result = unassign!

    expect(result.purged_count).to eq(2)
    expect(result.purged_node_ids).to contain_exactly(node_a.id, node_b.id)
    expect(result.to_payload[:purged_assignments]).to include(count: 2)
    expect(result.to_payload.dig(:purged_assignments, :node_ids)).to contain_exactly(node_a.id, node_b.id)
  end

  # The agent fails closed on a list naming no data-bearing module, so a
  # removal it must honour has to be RECORDED. A per-row destroy! runs the
  # model's after_destroy; a delete_all would skip it.
  it "records a clearance for each purged (node, module) so the agent may detach it" do
    unassign!

    [ node_a, node_b ].each do |n|
      expect(System::NodeAssignmentClearance.where(node_id: n.id, node_module_id: removed_mod.id)).to exist
    end
  end

  it "purges the rows of a DISABLED join too — disabling kept them, unassigning must not orphan them" do
    removed_join.update!(enabled: false)

    result = unassign!

    expect(result.purged_count).to eq(2)
    expect(System::NodeModuleAssignment.where(node_module_id: removed_mod.id)).to be_empty
  end

  context "when a transitive dependency of the removed join is still required through another join" do
    let(:shared_dep) { node_module("shared-dep") }

    # Both joins require the dependency at the same distance; the higher
    # priority join wins the attribution, so the dep's rows carry the REMOVED
    # join's id even though the kept join also needs it.
    let!(:removed_join) { join!(removed_mod, priority: 90) }
    let!(:kept_join)    { join!(kept_mod, priority: 10) }

    before do
      create(:system_module_dependency, node_module: removed_mod, dependency: shared_dep)
      create(:system_module_dependency, node_module: kept_mod, dependency: shared_dep)
      [ node_a, node_b ].each { |n| System::TemplateApplyService.new(n).apply! }
    end

    it "re-points the dependency's rows at the join that still requires it instead of destroying them" do
      dep_rows = System::NodeModuleAssignment.where(node_module_id: shared_dep.id)
      expect(dep_rows.pluck(:source_template_module_id).uniq).to eq([ removed_join.id ])

      result = unassign!

      expect(dep_rows.reload.count).to eq(2)
      expect(dep_rows.pluck(:source_template_module_id).uniq).to eq([ kept_join.id ])
      expect(result.repointed.map { |r| r[:node_module_id] }.uniq).to eq([ shared_dep.id ])
      expect(result.purged.map { |r| r[:node_module_id] }.uniq).to eq([ removed_mod.id ])
    end
  end

  context "when the removed join's transitive dependency is required by nothing else" do
    let(:only_dep) { node_module("only-dep") }

    before do
      create(:system_module_dependency, node_module: removed_mod, dependency: only_dep)
      [ node_a, node_b ].each { |n| System::TemplateApplyService.new(n).apply! }
    end

    it "purges the dependency's rows along with the module's" do
      result = unassign!

      expect(System::NodeModuleAssignment.where(node_module_id: [ removed_mod.id, only_dep.id ])).to be_empty
      expect(result.purged_count).to eq(4)
    end
  end

  # A fleet-sized template must not turn the reply or the event's jsonb into a
  # megabyte list: the counts stay exact, the lists are capped and flagged.
  it "caps the listed node ids and rows, keeping the counts exact" do
    stub_const("#{described_class}::LISTED_LIMIT", 1)

    payload = unassign!.to_payload[:purged_assignments]

    expect(payload).to include(count: 2, node_count: 2, truncated: true)
    expect(payload[:node_ids].size).to eq(1)
    expect(payload[:assignments].size).to eq(1)
  end

  it "records no blast radius when the template carries no live fleet" do
    expect(unassign!.blast_radius).to be_nil
    expect(System::FleetEvent.where(account: account, kind: "system.template_mutation")).to be_empty
  end

  it "writes nothing when a purge fails part-way — the join and every row survive" do
    allow_any_instance_of(System::TemplateModule).to receive(:destroy!).and_raise(ActiveRecord::RecordNotDestroyed)

    expect { unassign! }.to raise_error(ActiveRecord::RecordNotDestroyed)

    expect(System::TemplateModule.exists?(removed_join.id)).to be true
    expect(derived_rows.count).to eq(2)
  end
end
