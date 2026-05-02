# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse M6.F — ModuleComposeExecutor skill.
RSpec.describe System::Ai::Skills::ModuleComposeExecutor do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:exec)     { described_class.new(account: account) }

  describe ".descriptor" do
    it "advertises description input" do
      d = described_class.descriptor
      expect(d[:name]).to eq("module_compose")
      expect(d.dig(:inputs, :description, :required)).to be true
    end
  end

  describe "#execute" do
    context "with a description that hits no module names" do
      before do
        create(:system_node_module, account: account, node_platform: platform,
               category: category, variety: "subscription", name: "frobnicator")
      end

      it "returns an empty composition with reasoning" do
        r = exec.execute(description: "kubernetes service mesh")
        expect(r[:success]).to be true
        d = r[:data]
        expect(d[:draft_template][:modules]).to be_empty
        expect(d[:reasoning]).to match(/No modules matched/)
      end
    end

    context "with description matching multiple modules" do
      before do
        create(:system_node_module, account: account, node_platform: platform,
               category: category, variety: "subscription", name: "nginx")
        create(:system_node_module, account: account, node_platform: platform,
               category: category, variety: "subscription", name: "certbot")
        create(:system_node_module, account: account, node_platform: platform,
               category: category, variety: "subscription", name: "postgresql")
      end

      it "ranks matches by token overlap" do
        r = exec.execute(description: "nginx with certbot SSL termination")
        d = r[:data]
        names = d[:draft_template][:modules].map { |m| m[:name] }
        expect(names).to include("nginx", "certbot")
        expect(names).not_to include("postgresql")
        expect(d[:draft_template][:modules].first[:score]).to be > 0
      end

      it "suggests a hyphenated template name from description tokens" do
        r = exec.execute(description: "nginx web reverse proxy")
        expect(r[:data][:draft_template][:name_suggestion]).to match(/-template\z/)
      end
    end

    context "with two instance-variety modules in the same category" do
      let!(:instance_a) do
        create(:system_node_module, account: account, node_platform: platform,
               category: category, variety: "instance", name: "redis-instance-a")
      end
      let!(:instance_b) do
        create(:system_node_module, account: account, node_platform: platform,
               category: category, variety: "instance", name: "redis-instance-b")
      end

      it "flags an instance_variety_collision conflict" do
        r = exec.execute(description: "redis instance")
        conflicts = r[:data][:conflicts]
        expect(conflicts).not_to be_empty
        expect(conflicts.first[:kind]).to eq("instance_variety_collision")
      end
    end

    context "with empty/stopword-only description" do
      it "fails fast" do
        r = exec.execute(description: "the and a is")
        expect(r[:success]).to be false
        expect(r[:error]).to match(/at least one non-stopword/)
      end
    end

    context "scoped to a specific platform_id" do
      let(:other_platform) { create(:system_node_platform, account: account) }

      before do
        create(:system_node_module, account: account, node_platform: platform,
               category: category, variety: "subscription", name: "nginx-here")
        create(:system_node_module, account: account, node_platform: other_platform,
               category: category, variety: "subscription", name: "nginx-elsewhere")
      end

      it "limits candidates to the given platform" do
        r = exec.execute(description: "nginx web server", platform_id: platform.id)
        names = r[:data][:draft_template][:modules].map { |m| m[:name] }
        expect(names).to include("nginx-here")
        expect(names).not_to include("nginx-elsewhere")
      end
    end
  end
end
