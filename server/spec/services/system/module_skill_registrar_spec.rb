# frozen_string_literal: true

require "rails_helper"

# Golden Eclipse Block D — ModuleSkillRegistrar parses manifest.yaml#skills
# and creates Ai::Skill rows.
RSpec.describe System::ModuleSkillRegistrar do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account) }
  let(:mod) do
    create(:system_node_module, account: account, node_platform: platform,
           category: category, variety: "subscription", name: "vector-db")
  end

  describe ".register_for_module!" do
    context "with no manifest_yaml" do
      it "returns ok? with 0 registered" do
        result = described_class.register_for_module!(node_module: mod)
        expect(result.ok?).to be true
        expect(result.registered).to eq(0)
      end
    end

    context "with manifest declaring two skills (verified-publisher tier — direct register)" do
      let(:manifest) do
        <<~YAML
          schema_version: 1
          name: vector-db
          skills:
            - name: semantic_search
              description: Search this module's vector store
              category: data
              commands:
                - search_vectors
            - name: similarity_score
              description: Score document similarity
              category: research
        YAML
      end

      before do
        if mod.respond_to?(:manifest_yaml=)
          mod.update!(
            manifest_yaml: manifest,
            cosign_identity_regexp: ".*@verified.publisher",
            cosign_issuer_regexp: "https://gitea.example/oauth"
          )
        end
      end

      it "creates two Ai::Skill rows scoped to the module's account", skip: !System::NodeModule.column_names.include?("manifest_yaml") do
        expect {
          result = described_class.register_for_module!(node_module: mod)
          expect(result.ok?).to be true
          expect(result.registered).to eq(2)
        }.to change(Ai::Skill, :count).by(2)

        skill = Ai::Skill.find_by(slug: "module.#{mod.id}.semantic_search")
        expect(skill).to be_present
        expect(skill.name).to eq("vector-db::semantic_search")
        expect(skill.tags).to include("module-skill", "module:#{mod.id}", "tier:verified-publisher")
        expect(skill.category).to eq("data")
        expect(skill.commands).to include("search_vectors")
      end

      it "is idempotent on re-run", skip: !System::NodeModule.column_names.include?("manifest_yaml") do
        described_class.register_for_module!(node_module: mod)
        expect {
          described_class.register_for_module!(node_module: mod)
        }.not_to change(Ai::Skill, :count)
      end
    end

    context "with manifest declaring skills (community tier — proposal gate)" do
      let(:manifest) do
        <<~YAML
          skills:
            - name: untrusted_op
        YAML
      end

      before do
        # No cosign policy → community tier
        mod.update!(manifest_yaml: manifest) if mod.respond_to?(:manifest_yaml=)
      end

      it "routes through Ai::SkillProposal instead of creating Skill directly",
         skip: !System::NodeModule.column_names.include?("manifest_yaml") || !defined?(::Ai::SkillProposal) do
        expect {
          result = described_class.register_for_module!(node_module: mod)
          expect(result.ok?).to be true
          expect(result.registered).to eq(0)
          expect(result.proposed).to eq(1)
        }.not_to change(Ai::Skill, :count)
      end

      it "registers directly when SkillProposal model isn't defined (back-compat)",
         skip: !System::NodeModule.column_names.include?("manifest_yaml") || defined?(::Ai::SkillProposal) do
        expect {
          described_class.register_for_module!(node_module: mod)
        }.to change(Ai::Skill, :count).by(1)
      end
    end

    context "with cosign trust policy set (verified-publisher tier)" do
      let(:manifest) do
        <<~YAML
          skills:
            - name: trusted_op
        YAML
      end

      before do
        if mod.respond_to?(:manifest_yaml=)
          mod.update!(
            manifest_yaml: manifest,
            cosign_identity_regexp: ".*@example.org",
            cosign_issuer_regexp: "https://gitea.example/oauth"
          )
        end
      end

      it "tags the skill with tier:verified-publisher", skip: !System::NodeModule.column_names.include?("manifest_yaml") do
        described_class.register_for_module!(node_module: mod)
        skill = Ai::Skill.find_by("slug LIKE ?", "module.#{mod.id}.%")
        expect(skill.tags).to include("tier:verified-publisher")
      end
    end
  end

  describe ".unregister_for_module!" do
    it "removes all module skills for the given module" do
      Ai::Skill.create!(account: account, name: "vector-db::s1",
                        slug: "module.#{mod.id}.s1", category: "data", status: "active")
      Ai::Skill.create!(account: account, name: "other::s",
                        slug: "module.other.s", category: "data", status: "active")

      expect {
        result = described_class.unregister_for_module!(node_module: mod)
        expect(result.ok?).to be true
        expect(result.removed).to eq(1)
      }.to change(Ai::Skill, :count).by(-1)
    end
  end
end
