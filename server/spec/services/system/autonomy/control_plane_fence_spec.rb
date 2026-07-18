# frozen_string_literal: true

require "rails_helper"

# Autonomy safety rail (increment #28 / imp 019f6d6b-63e5): the shared
# control-plane fence. A reconciler must act only on instances owned by its
# OWN control plane. Read-side only — nothing here stamps owners (that is #14).
RSpec.describe System::Autonomy::ControlPlaneFence do
  # Minimal host that mixes in the fence (it needs no account — self-id is a
  # global deployment identity).
  let(:host) { Class.new { include System::Autonomy::ControlPlaneFence }.new }

  def instance_owned_by(owner)
    instance_double(System::NodeInstance, config: owner.nil? ? {} : { "control_plane_id" => owner })
  end

  describe "#control_plane_self_id" do
    it "is nil when the SiteSetting is unset (single-plane default)" do
      expect(host.control_plane_self_id).to be_nil
    end

    it "reflects the configured global SiteSetting" do
      SiteSetting.set("control_plane_id", "plane-A")
      expect(host.control_plane_self_id).to eq("plane-A")
    end
  end

  describe "#owned_by_this_control_plane?" do
    context "single-plane — self-id nil, fence fully inert" do
      it "is true regardless of the instance's stamped owner" do
        expect(host.owned_by_this_control_plane?(instance_owned_by("plane-B"))).to be true
        expect(host.owned_by_this_control_plane?(instance_owned_by(nil))).to be true
      end
    end

    context "with a configured self-id (plane-A)" do
      before { SiteSetting.set("control_plane_id", "plane-A") }

      it "reconciles unclaimed instances (owner nil)" do
        expect(host.owned_by_this_control_plane?(instance_owned_by(nil))).to be true
      end

      it "reconciles its own instances (owner == self)" do
        expect(host.owned_by_this_control_plane?(instance_owned_by("plane-A"))).to be true
      end

      it "skips instances owned by another plane (owner != self)" do
        expect(host.owned_by_this_control_plane?(instance_owned_by("plane-B"))).to be false
      end
    end
  end

  describe "#fence_to_control_plane" do
    let(:account) { create(:account) }
    let(:node)    { create(:system_node, account: account) }
    let!(:unclaimed) { create(:system_node_instance, node: node, config: {}) }
    let!(:ours)      { create(:system_node_instance, node: node, config: { "control_plane_id" => "plane-A" }) }
    let!(:theirs)    { create(:system_node_instance, node: node, config: { "control_plane_id" => "plane-B" }) }
    let(:relation)   { System::NodeInstance.where(account_id: account.id) }

    it "returns the relation unchanged for a single-plane deployment (self-id nil)" do
      expect(host.fence_to_control_plane(relation).to_sql).to eq(relation.to_sql)
      expect(host.fence_to_control_plane(relation)).to match_array([ unclaimed, ours, theirs ])
    end

    it "excludes other planes' instances (keeps unclaimed + ours) when self-id is set" do
      SiteSetting.set("control_plane_id", "plane-A")
      expect(host.fence_to_control_plane(relation)).to match_array([ unclaimed, ours ])
    end
  end
end
