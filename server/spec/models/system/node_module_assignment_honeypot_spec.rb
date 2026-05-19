# frozen_string_literal: true

require "rails_helper"

# Audit plan P2.8c — regression spec for the after_commit hook that
# auto-fires CanaryModuleService.observe_access! when a honeypot canary
# module gets attached to a node.
RSpec.describe System::NodeModuleAssignment, "honeypot auto-wiring" do
  let(:account) { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:node) { create(:system_node, account: account, node_template: create(:system_node_template, account: account)) }

  let(:plain_module) do
    create(:system_node_module, account: account, node_platform: platform, category: category,
                                 name: "plain-mod-#{SecureRandom.hex(3)}")
  end
  let(:canary_module) do
    mod = create(:system_node_module, account: account, node_platform: platform, category: category,
                                       name: "canary-secrets-store-#{SecureRandom.hex(3)}")
    System::Honeypot::CanaryModuleService.mark!(node_module: mod, lure_kind: "credential_store")
    mod.reload
  end

  it "does NOT emit honeypot_triggered when a non-canary module is attached" do
    expect {
      create(:system_node_module_assignment, node: node, node_module: plain_module)
    }.not_to change { System::FleetEvent.where(kind: "system.honeypot_triggered").count }
  end

  it "DOES emit honeypot_triggered when a canary module is attached" do
    expect {
      create(:system_node_module_assignment, node: node, node_module: canary_module)
    }.to change { System::FleetEvent.where(kind: "system.honeypot_triggered").count }.by(1)
  end

  it "the emitted event has the correct payload shape + severity" do
    assignment = create(:system_node_module_assignment, node: node, node_module: canary_module)
    event = System::FleetEvent.where(kind: "system.honeypot_triggered").order(created_at: :desc).first

    expect(event.severity).to eq("high")
    expect(event.source).to eq("honeypot")
    expect(event.node_module_id).to eq(canary_module.id)
    expect(event.payload).to include(
      "module_id" => canary_module.id,
      "module_name" => canary_module.name,
      "source" => "node_module_assignment"
    )
    expect(event.payload.dig("context", "node_id")).to eq(node.id)
    expect(event.payload.dig("context", "assignment_id")).to eq(assignment.id)
  end

  it "does not raise if the assignment is rolled back after the after_commit hook" do
    # The hook runs after_commit, so a rolled-back assignment shouldn't trigger.
    # This verifies the assignment isn't accidentally creating events outside
    # the commit boundary.
    expect {
      ActiveRecord::Base.transaction do
        create(:system_node_module_assignment, node: node, node_module: canary_module)
        raise ActiveRecord::Rollback
      end
    }.not_to change { System::FleetEvent.where(kind: "system.honeypot_triggered").count }
  end
end
