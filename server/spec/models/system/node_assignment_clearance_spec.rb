# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::NodeAssignmentClearance do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform, name: "t-#{SecureRandom.hex(3)}") }
  let(:node)     { create(:system_node, account: account, node_template: template, name: "n-#{SecureRandom.hex(3)}") }

  def build_row(**over)
    described_class.new({ account: account, node: node, node_module_id: SecureRandom.uuid, reason: "assignment_destroyed",
                          issued_at: Time.current, expires_at: 1.day.from_now }.merge(over))
  end

  it "is valid with a node, a module id, a known reason and a window" do
    expect(build_row).to be_valid
  end

  it "refuses a reason the platform does not issue" do
    expect(build_row(reason: "because")).not_to be_valid
  end

  it "refuses a window that ends before it begins" do
    expect(build_row(issued_at: Time.current, expires_at: 1.minute.ago)).not_to be_valid
  end

  it "holds one clearance per (node, module)" do
    row = build_row
    row.save!
    expect(build_row(node_module_id: row.node_module_id)).not_to be_valid
  end

  it "is scoped by live/expired" do
    live = build_row.tap(&:save!)
    dead = build_row(expires_at: 1.hour.from_now).tap(&:save!)
    dead.update_columns(expires_at: 1.minute.ago)

    expect(described_class.live.pluck(:id)).to eq([ live.id ])
  end

  it "goes with its node" do
    build_row.save!
    expect { node.destroy! }.to change { described_class.count }.by(-1)
  end
end
