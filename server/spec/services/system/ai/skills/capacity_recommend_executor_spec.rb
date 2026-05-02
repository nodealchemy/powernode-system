# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M6.E — CapacityRecommendExecutor skill.
RSpec.describe System::Ai::Skills::CapacityRecommendExecutor do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:template) { create(:system_node_template, account: account, node_platform: platform) }
  let(:exec)     { described_class.new(account: account) }

  describe ".descriptor" do
    it "advertises template_id input" do
      d = described_class.descriptor
      expect(d[:name]).to eq("capacity_recommend")
      expect(d.dig(:inputs, :template_id, :required)).to be true
    end
  end

  describe "#execute" do
    context "with no instances" do
      it "recommends scale_up to reach target_min_active" do
        r = exec.execute(template_id: template.id, target_min_active: 2)
        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:active_count]).to eq(0)
        expect(d[:recommendation][:action]).to eq("scale_up")
        expect(d[:recommendation][:delta]).to eq(2)
        expect(d[:recommendation][:suggested_skill]).to eq("provision_cluster")
      end
    end

    context "with healthy active instances at target" do
      before do
        node = create(:system_node, account: account, node_template: template)
        instance = create(:system_node_instance, :running, node: node)
        instance.update!(last_heartbeat_at: 30.seconds.ago)
      end

      it "returns no_change" do
        r = exec.execute(template_id: template.id, target_min_active: 1)
        expect(r[:data][:recommendation][:action]).to eq("no_change")
      end
    end

    context "with silent instances dominating the fleet" do
      before do
        4.times do |i|
          node = create(:system_node, account: account, node_template: template, name: "n-#{i}")
          inst = create(:system_node_instance, :running, node: node)
          # all silent
          inst.update!(last_heartbeat_at: 1.hour.ago)
        end
      end

      it "recommends investigate_silent" do
        r = exec.execute(template_id: template.id, target_min_active: 0)
        d = r[:data]
        expect(d[:silent_count]).to eq(4)
        expect(d[:recommendation][:action]).to eq("investigate_silent")
        expect(d[:recommendation][:suggested_skill]).to eq("drift_remediate")
      end
    end

    context "with errored instances" do
      before do
        node = create(:system_node, account: account, node_template: template)
        instance = create(:system_node_instance, :running, node: node)
        instance.update_columns(status: "error")
      end

      it "recommends remediate_errored" do
        r = exec.execute(template_id: template.id, target_min_active: 0)
        expect(r[:data][:recommendation][:action]).to eq("remediate_errored")
      end
    end

    context "when template is missing" do
      it "fails fast" do
        r = exec.execute(template_id: SecureRandom.uuid)
        expect(r[:success]).to be false
        expect(r[:error]).to match(/template lookup failed/)
      end
    end
  end
end
