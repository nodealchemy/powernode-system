# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse Block J2 — AttributeFailureExecutor.
RSpec.describe System::Ai::Skills::AttributeFailureExecutor do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:instance) { create(:system_node_instance, :running, node: node) }
  let(:exec)     { described_class.new(account: account) }

  let(:mod) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription", name: "suspect-mod")
  end

  describe ".descriptor" do
    it "advertises required inputs" do
      d = described_class.descriptor
      expect(d[:name]).to eq("attribute_failure")
      expect(d.dig(:inputs, :instance_id, :required)).to be true
    end
  end

  describe "#execute" do
    context "with no recent changes" do
      it "returns empty candidates with explanatory reasoning" do
        r = exec.execute(instance_id: instance.id)
        expect(r[:success]).to be true
        expect(r[:data][:candidates]).to be_empty
        expect(r[:data][:reasoning]).to match(/No suspect changes/)
      end
    end

    context "with a recent assignment change" do
      before do
        System::NodeModuleAssignment.create!(node: node, node_module: mod, enabled: true, priority: 0)
      end

      it "scores the assignment change as a candidate" do
        r = exec.execute(instance_id: instance.id)
        expect(r[:success]).to be true
        cands = r[:data][:candidates]
        expect(cands.size).to be >= 1
        expect(cands.first[:kind]).to eq("assignment_change")
        expect(cands.first[:module_id]).to eq(mod.id)
      end
    end

    context "with a recent live promotion" do
      let!(:version) do
        v = System::NodeModuleVersion.create!(
          node_module: mod, version_number: 1,
          mask: [], file_spec: [], package_spec: [], config: {},
          oci_digest: "sha256:#{'a' * 64}",
          live_at: 1.hour.ago
        )
        node.node_modules << mod
        v
      end

      it "scores the promotion as a high-weight candidate" do
        r = exec.execute(instance_id: instance.id)
        cands = r[:data][:candidates]
        promo = cands.find { |c| c[:kind] == "promotion" }
        expect(promo).to be_present
        expect(promo[:score]).to be >= 12 # live promotion base weight
      end
    end

    context "with a non-existent instance" do
      it "fails fast" do
        r = exec.execute(instance_id: SecureRandom.uuid)
        expect(r[:success]).to be false
        expect(r[:error]).to match(/instance not found/)
      end
    end

    context "with attribution feedback boosting a confirmed candidate" do
      before do
        System::NodeModuleAssignment.create!(node: node, node_module: mod, enabled: true, priority: 0)
        # Pre-existing confirmed feedback for this (kind, module_id) pair
        Ai::CompoundLearning.create!(
          account_id: account.id,
          ai_agent_team_id: nil,
          title: "Past confirmation",
          content: "test",
          category: "discovery",
          scope: "team",
          tags: [ "fleet", "attribution", "module:#{mod.id}", "kind:assignment_change", "outcome:confirmed" ],
          status: "active",
          confidence_score: 0.7,
          importance_score: 0.7
        )
      end

      it "applies the 1.5x score multiplier from confirmed feedback" do
        r = exec.execute(instance_id: instance.id)
        top = r[:data][:top_candidate]
        expect(top[:feedback]).to eq("boosted_by_prior_confirmation")
        # Base score for assignment_change is 5 → 1.5x = 7.5 → rounded 8
        expect(top[:score]).to eq(8)
      end
    end

    context "with attribution feedback rejecting a candidate" do
      before do
        System::NodeModuleAssignment.create!(node: node, node_module: mod, enabled: true, priority: 0)
        Ai::CompoundLearning.create!(
          account_id: account.id,
          ai_agent_team_id: nil,
          title: "Past rejection",
          content: "test",
          category: "failure_mode",
          scope: "team",
          tags: [ "fleet", "attribution", "module:#{mod.id}", "kind:assignment_change", "outcome:rejected" ],
          status: "active",
          confidence_score: 0.5,
          importance_score: 0.4
        )
      end

      it "applies the 0.7x downweight from rejected feedback" do
        r = exec.execute(instance_id: instance.id)
        top = r[:data][:top_candidate]
        expect(top[:feedback]).to eq("downweighted_by_prior_rejection")
        expect(top[:score]).to eq(4) # 5 * 0.7 = 3.5 → rounded 4
      end
    end
  end
end
