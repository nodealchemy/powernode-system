# frozen_string_literal: true

require "rails_helper"

# RCP v2 (campaign 019f9250, increment p0c) — INV-1: no self-management.
# Mirrors control_plane_fence_spec.rb's structure deliberately: this is a
# sibling fence, not a variant of that one (see SelfManagementFence's doc
# comment for why they are distinct).
RSpec.describe System::Autonomy::SelfManagementFence do
  let(:host) { Class.new { include System::Autonomy::SelfManagementFence }.new }
  let(:account) { create(:account) }
  let(:node) { create(:system_node, account: account) }
  let(:other_node) { create(:system_node, account: account) }

  describe "#self_hosting_node_id" do
    it "is nil when the SiteSetting is unset (the default — fence fully inert)" do
      expect(host.self_hosting_node_id).to be_nil
    end

    it "reflects the configured global SiteSetting" do
      SiteSetting.set("self_hosting_node_id", node.id)
      expect(host.self_hosting_node_id).to eq(node.id)
    end
  end

  describe "#self_managed_target?" do
    context "unconfigured — fence fully inert" do
      it "is false for a System::Node regardless of which node" do
        expect(host.self_managed_target?(node)).to be false
      end

      it "is false for a System::NodeInstance" do
        instance = create(:system_node_instance, node: node)
        expect(host.self_managed_target?(instance)).to be false
      end
    end

    context "with a configured self_hosting_node_id" do
      before { SiteSetting.set("self_hosting_node_id", node.id) }

      it "is true for the matching System::Node" do
        expect(host.self_managed_target?(node)).to be true
      end

      it "is false for a different System::Node" do
        expect(host.self_managed_target?(other_node)).to be false
      end

      it "is true for a NodeInstance whose node is the self-hosting node" do
        instance = create(:system_node_instance, node: node)
        expect(host.self_managed_target?(instance)).to be true
      end

      it "is false for a NodeInstance on a different node" do
        instance = create(:system_node_instance, node: other_node)
        expect(host.self_managed_target?(instance)).to be false
      end

      it "resolves a raw node-id string the same way" do
        expect(host.self_managed_target?(node.id)).to be true
        expect(host.self_managed_target?(other_node.id)).to be false
      end
    end
  end

  describe "#assert_not_self_managed!" do
    it "is a no-op when unconfigured" do
      expect { host.assert_not_self_managed!(node, action: "terminate") }.not_to raise_error
    end

    it "is a no-op for a non-self target even when configured" do
      SiteSetting.set("self_hosting_node_id", node.id)
      expect { host.assert_not_self_managed!(other_node, action: "terminate") }.not_to raise_error
    end

    it "raises SelfManagementViolation for the self-hosting node when configured" do
      SiteSetting.set("self_hosting_node_id", node.id)
      expect { host.assert_not_self_managed!(node, action: "terminate") }
        .to raise_error(System::Autonomy::SelfManagementFence::SelfManagementViolation, /terminate/)
    end

    it "raises for a NodeInstance hosted on the self-managed node" do
      SiteSetting.set("self_hosting_node_id", node.id)
      instance = create(:system_node_instance, node: node)
      expect { host.assert_not_self_managed!(instance, action: "provision an instance onto") }
        .to raise_error(System::Autonomy::SelfManagementFence::SelfManagementViolation, /INV-1/)
    end
  end
end
