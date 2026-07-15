# frozen_string_literal: true

require "rails_helper"

# Campaign 019f6084 inc3, Deliverable 2 — template-mutation blast-radius gate.
RSpec.describe System::Ai::Skills::TemplateApprovalPolicy do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }

  it "does not require approval for a NEW template (nil target)" do
    c = described_class.for(template: nil)
    expect(c.requires_approval?).to be false
    expect(c.new_template).to be true
    expect(c.provisioned_node_count).to eq(0)
  end

  it "does not require approval for an existing template with no provisioned nodes" do
    c = described_class.for(template: template)
    expect(c.requires_approval?).to be false
    expect(c.new_template).to be false
    expect(c.provisioned_node_count).to eq(0)
  end

  it "REQUIRES approval for an existing template with a provisioned (live) node" do
    node = create(:system_node, account: account, node_template: template)
    create(:system_node_instance, :running, node: node)

    c = described_class.for(template: template)
    expect(c.requires_approval?).to be true
    expect(c.provisioned_node_count).to eq(1)
    expect(c.reason).to match(/propagates to live fleet/)
  end
end
