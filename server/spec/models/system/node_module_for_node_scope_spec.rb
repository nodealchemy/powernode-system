# frozen_string_literal: true

require "rails_helper"

# IMP-843c223063cf — NodeModule.for_node was defined twice: an early
# direct-column filter (where(node_id:)) shadowed by the later
# assignment-join version. Ruby silently kept the join version; the dead
# early definition misled anyone auditing node-scoping. This spec pins
# (a) that exactly one definition remains and (b) the JOIN semantics —
# membership comes from NodeModuleAssignment rows, NOT the legacy
# node_id column.
RSpec.describe System::NodeModule, "for_node scope" do
  it "is defined exactly once in the model source" do
    source = File.read(
      Rails.root.join("../extensions/system/server/app/models/system/node_module.rb")
    )
    expect(source.scan(/scope :for_node\b/).count).to eq(1)
  end

  describe "join semantics" do
    let(:account) { create(:account) }
    let(:node) { create(:system_node, account: account) }

    it "returns modules attached via assignments, ignoring the legacy node_id column" do
      attached = create(:system_node_module, account: account, name: "attached-mod")
      create(:system_node_module_assignment, node: node, node_module: attached)

      # Legacy column set but NO assignment row — must NOT appear.
      column_only = create(:system_node_module, account: account, name: "column-only-mod")
      column_only.update_column(:node_id, node.id)

      result = described_class.for_node(node.id)

      expect(result).to include(attached)
      expect(result).not_to include(column_only)
    end
  end
end
