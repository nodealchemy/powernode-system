# frozen_string_literal: true

require "rails_helper"

# IMP-9f4e162d9ed1 — every server action that takes a module off a node's served
# list records a clearance for it, so the agent (which fails closed on an empty
# list) can be told the removal was deliberate. Driven through the REAL entry
# points of the five flows the task names, not through the callbacks directly.
RSpec.describe "assignment clearance across the unassign flows" do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account, name: "cat-#{SecureRandom.hex(3)}") }
  let(:template) { create(:system_node_template, account: account, node_platform: platform, name: "tmpl-#{SecureRandom.hex(3)}") }
  let(:empty_template) { create(:system_node_template, account: account, node_platform: platform, name: "empty-#{SecureRandom.hex(3)}") }
  let(:node) { create(:system_node, account: account, node_template: template, name: "node-#{SecureRandom.hex(3)}") }

  def node_module(name = "m")
    create(:system_node_module, account: account, node_platform: platform, category: category,
           variety: "subscription", name: "#{name}-#{SecureRandom.hex(3)}")
  end

  def clearances(for_node = node)
    System::NodeAssignmentClearance.where(node_id: for_node.id)
  end

  describe "E1/E2/E3 — a purging template apply that empties the node" do
    let!(:mod) { node_module("templated") }
    let!(:join) { System::TemplateModule.create!(node_template: template, node_module: mod, enabled: true) }

    before { System::TemplateApplyService.new(node).apply! }

    it "E1: re-templating through system_update_node onto a template with NO modules clears the module" do
      tool = Ai::Tools::SystemFleetTool.new(account: account, internal: true)

      tool.execute(params: { action: "system_update_node", node_id: node.id, node_template_id: empty_template.id })

      expect(node.reload.node_module_assignments).to be_empty
      expect(clearances.pluck(:node_module_id)).to eq([ mod.id ])
      expect(clearances.first.reason).to eq("assignment_destroyed")
    end

    it "E3: disabling the template's last module, then a purging apply, clears it on the derived node" do
      join.update!(enabled: false)
      expect(clearances).to be_empty # nothing is removed until the purging apply

      # A fresh node: the memoised one holds the template's pre-disable join cache.
      System::TemplateApplyService.new(System::Node.find(node.id)).apply!(purge_stale: true)

      expect(clearances.pluck(:node_module_id)).to eq([ mod.id ])
    end

    it "a dry-run apply persists nothing, so it clears nothing" do
      join.update!(enabled: false)

      System::TemplateApplyService.new(System::Node.find(node.id)).apply!(dry_run: true, purge_stale: true)

      expect(clearances).to be_empty
    end
  end

  describe "E4 — disabling a node's assignment" do
    let!(:mod) { node_module("assigned") }
    let!(:assignment) { create(:system_node_module_assignment, node: node, node_module: mod, enabled: true) }

    it "clears the module when the assignment is disabled" do
      assignment.update!(enabled: false)

      expect(clearances.pluck(:node_module_id)).to eq([ mod.id ])
      expect(clearances.first.reason).to eq("assignment_disabled")
    end

    it "clears the module when the MCP verb system_update_module_assignment disables it" do
      tool = Ai::Tools::SystemFleetTool.new(account: account, internal: true)

      tool.execute(params: { action: "system_update_module_assignment", assignment_id: assignment.id, enabled: false })

      expect(clearances.pluck(:node_module_id)).to eq([ mod.id ])
    end

    it "revokes the clearance when the assignment is enabled again" do
      assignment.update!(enabled: false)
      assignment.update!(enabled: true)

      expect(clearances).to be_empty
    end

    it "clears the module when the assignment row is removed" do
      assignment.destroy!

      expect(clearances.pluck(:node_module_id)).to eq([ mod.id ])
    end

    it "does not clear anything for an assignment that was already disabled" do
      assignment.update_columns(enabled: false)

      assignment.destroy!

      expect(clearances).to be_empty
    end

    it "does not clear on an update that leaves the enabled flag alone" do
      assignment.update!(priority: 77)

      expect(clearances).to be_empty
    end

    it "revokes the clearance when the module is assigned to the node again" do
      assignment.destroy!
      expect(clearances.count).to eq(1)

      create(:system_node_module_assignment, node: node, node_module: mod, enabled: true)

      expect(clearances).to be_empty
    end

    it "keeps clearing per module when one of several assignments is disabled" do
      other = node_module("kept")
      create(:system_node_module_assignment, node: node, node_module: other, enabled: true)

      assignment.update!(enabled: false)

      expect(clearances.pluck(:node_module_id)).to eq([ mod.id ])
    end
  end

  describe "E5 — disabling a NodeModule globally" do
    let!(:mod) { node_module("shared") }
    let(:other_node) { create(:system_node, account: account, node_template: template, name: "other-#{SecureRandom.hex(3)}") }

    before do
      create(:system_node_module_assignment, node: node, node_module: mod, enabled: true)
      create(:system_node_module_assignment, node: other_node, node_module: mod, enabled: true)
    end

    it "clears the module on every node that serves it" do
      mod.update!(enabled: false)

      expect(clearances(node).pluck(:node_module_id)).to eq([ mod.id ])
      expect(clearances(other_node).pluck(:node_module_id)).to eq([ mod.id ])
      expect(clearances(node).first.reason).to eq("module_disabled")
    end

    it "revokes them when the module is enabled again" do
      mod.update!(enabled: false)
      mod.update!(enabled: true)

      expect(System::NodeAssignmentClearance.where(node_module_id: mod.id)).to be_empty
    end

    it "does not fire on an update that leaves the enabled flag alone" do
      mod.update!(description: "changed")

      expect(System::NodeAssignmentClearance.where(node_module_id: mod.id)).to be_empty
    end

    it "clears the module on every node when the module itself is destroyed" do
      mod.destroy!

      expect(System::NodeAssignmentClearance.where(node_module_id: mod.id).pluck(:node_id))
        .to contain_exactly(node.id, other_node.id)
    end

    it "clears a dependant child on its node when the child is disabled or destroyed" do
      child = create(:system_node_module, account: account, node_platform: platform, category: category,
                     variety: "config", parent_module: mod, node: node, name: "child-#{SecureRandom.hex(3)}")

      child.update!(enabled: false)
      expect(clearances.pluck(:node_module_id)).to include(child.id)

      child.update!(enabled: true)
      expect(clearances.pluck(:node_module_id)).not_to include(child.id)

      child.destroy!
      expect(clearances.pluck(:node_module_id)).to include(child.id)
    end
  end

  describe "atomicity with the removal" do
    let!(:mod) { node_module("rolled-back") }
    let!(:assignment) { create(:system_node_module_assignment, node: node, node_module: mod, enabled: true) }

    it "a removal that rolls back records no clearance (system_update_node's explicit rollback)" do
      ActiveRecord::Base.transaction do
        assignment.destroy!
        raise ActiveRecord::Rollback
      end

      expect(System::NodeAssignmentClearance.count).to eq(0)
      expect(node.reload.node_module_assignments.count).to eq(1)
    end

    it "a failing clearance write does not block the operator's removal, and leaves no clearance (fail closed)" do
      allow(System::AssignmentClearanceService).to receive(:issue!).and_raise(ActiveRecord::StatementInvalid, "boom")

      expect { assignment.destroy! }.not_to raise_error
      expect(System::NodeModuleAssignment.exists?(assignment.id)).to be(false)
      expect(System::NodeAssignmentClearance.count).to eq(0)
    end
  end

  describe "the flows the task does NOT change" do
    it "destroying the node records no clearance for the assignments that go with it" do
      mod = node_module("with-node")
      create(:system_node_module_assignment, node: node, node_module: mod, enabled: true)

      expect { node.destroy! }.not_to change { System::NodeAssignmentClearance.count }
    end
  end
end
