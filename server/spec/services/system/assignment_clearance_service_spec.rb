# frozen_string_literal: true

require "rails_helper"

# IMP-9f4e162d9ed1 — the platform's per-module statement that it unassigned a
# module from a node. The agent fails closed on an assignment list that names no
# data-bearing module (IMP-1023e79cc82d); it detaches on such a list only a module
# named here. So the property that matters is that a clearance exists ONLY as the
# record of a real removal, and stops being served the moment the module is
# assigned again.
RSpec.describe System::AssignmentClearanceService do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account, name: "cat-#{SecureRandom.hex(3)}") }
  let(:template) { create(:system_node_template, account: account, node_platform: platform, name: "t-#{SecureRandom.hex(3)}") }
  let(:node)     { create(:system_node, account: account, node_template: template, name: "n-#{SecureRandom.hex(3)}") }

  def node_module(name = "m")
    create(:system_node_module, account: account, node_platform: platform, category: category,
           variety: "subscription", name: "#{name}-#{SecureRandom.hex(3)}")
  end

  describe ".issue!" do
    it "records one live clearance per module, with a reason and an expiry" do
      a = node_module("a")
      b = node_module("b")

      described_class.issue!(node: node, node_module_ids: [ a.id, b.id ], reason: "assignment_destroyed")

      rows = System::NodeAssignmentClearance.where(node_id: node.id)
      expect(rows.pluck(:node_module_id)).to contain_exactly(a.id, b.id)
      expect(rows.pluck(:reason).uniq).to eq([ "assignment_destroyed" ])
      expect(rows.pluck(:account_id).uniq).to eq([ account.id ])
      expect(rows.first.expires_at).to be > Time.current + 1.day
    end

    it "refreshes an existing clearance instead of duplicating it" do
      a = node_module("a")
      described_class.issue!(node: node, node_module_ids: [ a.id ], reason: "assignment_destroyed")
      first_expiry = System::NodeAssignmentClearance.find_by!(node_id: node.id, node_module_id: a.id).expires_at

      travel 2.hours do
        described_class.issue!(node: node, node_module_ids: [ a.id ], reason: "assignment_disabled")
      end

      rows = System::NodeAssignmentClearance.where(node_id: node.id, node_module_id: a.id)
      expect(rows.count).to eq(1)
      expect(rows.first.reason).to eq("assignment_disabled")
      expect(rows.first.expires_at).to be > first_expiry
    end

    it "writes ONE audit row for the batch, naming the reason and the modules" do
      a = node_module("a")
      b = node_module("b")

      expect {
        described_class.issue!(node: node, node_module_ids: [ a.id, b.id ], reason: "module_destroyed")
      }.to change { AuditLog.where(action: "system.assignment_clearance.issued").count }.by(1)

      log = AuditLog.where(action: "system.assignment_clearance.issued").last
      expect(log.resource_type).to eq("System::Node")
      expect(log.resource_id).to eq(node.id.to_s)
      expect(log.account_id).to eq(account.id)
      expect(log.metadata).to include("reason" => "module_destroyed", "module_count" => 2)
      expect(log.metadata["node_module_ids"]).to contain_exactly(a.id, b.id)
    end

    it "does nothing for an empty module list" do
      expect {
        described_class.issue!(node: node, node_module_ids: [], reason: "assignment_destroyed")
      }.not_to change { System::NodeAssignmentClearance.count }
    end

    it "does nothing for a node that no longer exists" do
      a = node_module("a")
      gone = node
      gone.destroy!

      expect {
        described_class.issue!(node: gone, node_module_ids: [ a.id ], reason: "assignment_destroyed")
      }.not_to change { System::NodeAssignmentClearance.count }
    end

    it "honours the operator TTL setting, floored so a bad value can only shorten to the floor" do
      a = node_module("a")
      allow(SiteSetting).to receive(:get).and_call_original
      allow(SiteSetting).to receive(:get).with("system.assignment_clearance.ttl_seconds").and_return("abc")

      described_class.issue!(node: node, node_module_ids: [ a.id ], reason: "assignment_destroyed")

      row = System::NodeAssignmentClearance.find_by!(node_id: node.id, node_module_id: a.id)
      expect(row.expires_at).to be_within(1.minute).of(Time.current + described_class::DEFAULT_TTL)

      allow(SiteSetting).to receive(:get).with("system.assignment_clearance.ttl_seconds").and_return("5")
      described_class.issue!(node: node, node_module_ids: [ a.id ], reason: "assignment_destroyed")
      expect(row.reload.expires_at).to be_within(1.minute).of(Time.current + described_class::TTL_FLOOR)
    end
  end

  describe ".issue_for_module!" do
    it "clears the module on EVERY node that serves it, one audit row for the module" do
      mod = node_module("shared")
      other_template = create(:system_node_template, account: account, node_platform: platform, name: "t2-#{SecureRandom.hex(3)}")
      other_node = create(:system_node, account: account, node_template: other_template, name: "n2-#{SecureRandom.hex(3)}")
      bystander = create(:system_node, account: account, node_template: template, name: "n3-#{SecureRandom.hex(3)}")
      create(:system_node_module_assignment, node: node, node_module: mod, enabled: true)
      create(:system_node_module_assignment, node: other_node, node_module: mod, enabled: true)
      # A node whose own assignment is already disabled never served the module.
      create(:system_node_module_assignment, node: bystander, node_module: mod, enabled: false)

      expect {
        described_class.issue_for_module!(node_module: mod, reason: "module_disabled")
      }.to change { AuditLog.where(action: "system.assignment_clearance.issued").count }.by(1)

      expect(System::NodeAssignmentClearance.where(node_module_id: mod.id).pluck(:node_id))
        .to contain_exactly(node.id, other_node.id)
      log = AuditLog.where(action: "system.assignment_clearance.issued").last
      expect(log.resource_type).to eq("System::NodeModule")
      expect(log.metadata).to include("reason" => "module_disabled", "node_count" => 2)
    end

    it "clears a dependant child on the one node it is bound to" do
      parent = node_module("parent")
      child = create(:system_node_module, account: account, node_platform: platform, category: category,
                     variety: "config", parent_module: parent, node: node, name: "child-#{SecureRandom.hex(3)}")

      described_class.issue_for_module!(node_module: child, reason: "module_disabled")

      expect(System::NodeAssignmentClearance.where(node_module_id: child.id).pluck(:node_id)).to eq([ node.id ])
    end
  end

  describe ".revoke!" do
    it "removes the clearance for the modules named and leaves the others" do
      a = node_module("a")
      b = node_module("b")
      described_class.issue!(node: node, node_module_ids: [ a.id, b.id ], reason: "assignment_destroyed")

      described_class.revoke!(node_id: node.id, node_module_ids: [ a.id ])

      expect(System::NodeAssignmentClearance.where(node_id: node.id).pluck(:node_module_id)).to eq([ b.id ])
    end

    it "clears a module on every node at once when no node is named" do
      a = node_module("a")
      other_template = create(:system_node_template, account: account, node_platform: platform, name: "t2-#{SecureRandom.hex(3)}")
      other = create(:system_node, account: account, node_template: other_template, name: "n2-#{SecureRandom.hex(3)}")
      described_class.issue!(node: node, node_module_ids: [ a.id ], reason: "module_disabled")
      described_class.issue!(node: other, node_module_ids: [ a.id ], reason: "module_disabled")

      described_class.revoke!(node_module_ids: [ a.id ])

      expect(System::NodeAssignmentClearance.where(node_module_id: a.id)).to be_empty
    end
  end

  describe ".served_for" do
    it "serves this node's live clearances only" do
      a = node_module("a")
      b = node_module("b")
      c = node_module("c")
      other_template = create(:system_node_template, account: account, node_platform: platform, name: "t2-#{SecureRandom.hex(3)}")
      other = create(:system_node, account: account, node_template: other_template, name: "n2-#{SecureRandom.hex(3)}")
      described_class.issue!(node: node, node_module_ids: [ a.id, b.id ], reason: "assignment_destroyed")
      described_class.issue!(node: other, node_module_ids: [ c.id ], reason: "assignment_destroyed")
      System::NodeAssignmentClearance.where(node_id: node.id, node_module_id: b.id).update_all(expires_at: 1.minute.ago)

      served = described_class.served_for(node)

      expect(served.map { |e| e[:module_id] }).to eq([ a.id ])
      expect(served.first).to include(reason: "assignment_destroyed")
      expect(served.first[:expires_at]).to be_present
    end

    it "is empty for a node with no clearance" do
      expect(described_class.served_for(node)).to eq([])
    end
  end
end
