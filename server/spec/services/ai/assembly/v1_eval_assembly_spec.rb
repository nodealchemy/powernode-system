# frozen_string_literal: true

require "rails_helper"

# PRE-2 acceptance: assemble_task on the six v1 eval tasks returns the expected
# skills for the agent that would take each, with every capability batch loaded
# (core's and this extension's), on the recorded real embeddings; and the
# fleet-operator's tier follows the work, not the agent: a mutating fleet task
# is raised to {reasoning, opus, high} by the skills' hints AND by verb risk,
# an inspect task stays {standard, sonnet, medium}.
RSpec.describe Ai::Assembly::Service, "v1 eval tasks", type: :service do
  let!(:account) { create(:account) }
  let(:core_seed) { Rails.root.join("db", "seeds", "ai_capability_skills_seed.rb") }
  let(:ext_seed) { Rails.root.join("../extensions/system/server/db/seeds/system_capability_skills_seed.rb").cleanpath }

  before do
    use_recorded_skill_embeddings!
    seed_with_baseline!(core_seed, ext_seed)
  end

  def assemble(task, agent_slug:)
    described_class.new(account: account).call(task: task, agent_slug: agent_slug, context: "claude_code")
  end

  {
    [ "Work a dev-improve task that adds a migration and a spec", "platform-engineer" ] => %w[dev-loop-execution rails-backend-conventions test-authoring],
    [ "Review this campaign increment against its acceptance criteria", "platform-reviewer" ] => %w[acceptance-criteria-review],
    [ "Provision a VM with attached storage for a new project", "fleet-operator" ] => %w[fleet-provisioning-entry storage-operations fleet-capacity-operations],
    [ "Help me onboard: I want to set up Powernode for my team", "powernode-concierge" ] => %w[front-door-triage provisioning-brief-capture],
    [ "Rotate the WireGuard key for an SD-WAN peer", "fleet-operator" ] => %w[sdwan-operations],
    [ "Deploy my app", "platform-engineer" ] => %w[deployment-handoff]
  }.each do |(task, agent), owners|
    it "#{agent}: #{task.inspect} selects #{owners.join(' or ')}" do
      slugs = assemble(task, agent_slug: agent)[:skills].map { |s| s[:slug] }

      expect(slugs & owners).not_to be_empty, "got #{slugs.inspect}"
    end
  end

  describe "fleet-operator tier" do
    it "raises a mutating fleet task to reasoning / opus / high" do
      result = assemble("Provision a VM with attached storage for a new project", agent_slug: "fleet-operator")

      expect(result).to include(tier: "reasoning", model: "opus", effort: "high")
      expect(result[:floor_reason]).to be_present
    end

    it "keeps an inspect task at standard / sonnet / medium" do
      result = assemble("Probe platform health and report what is down or degraded", agent_slug: "fleet-operator")

      expect(result[:skills].map { |s| s[:slug] }).to include("platform-health-probe")
      expect(result).to include(tier: "standard", model: "sonnet", effort: "medium")
    end

    it "keeps the inspect task standard although the probe names an approval-parking inspection verb (system_inspect_node)" do
      probe = Ai::Skill.global.find_by!(slug: "platform-health-probe")
      expect(probe.metadata.dig("manifest", "verbs")).to include("system_inspect_node")
      expect(Ai::Assembly::VerbRisk.new.gated?("system_inspect_node")).to be(true)
      expect(probe.metadata.dig("manifest", "gate_category")).to eq("read")
    end

    it "raises by verb risk alone: a skill with understated hints that names a gated fleet verb is still reasoning/high" do
      probe = Ai::Skill.global.find_by!(slug: "platform-health-probe")
      probe.update_columns(metadata: probe.metadata.merge(
        "manifest" => probe.metadata["manifest"].merge("verbs" => probe.metadata.dig("manifest", "verbs") + %w[system_expose_service_publicly],
                                                       "gate_category" => "mutate", "read_only" => false)
      ))
      expect(Ai::Assembly::VerbRisk.new.gated_verbs(%w[system_expose_service_publicly])).to eq([ "system_expose_service_publicly" ])

      result = assemble("Probe platform health and report what is down or degraded", agent_slug: "fleet-operator")

      expect(result).to include(tier: "reasoning", model: "opus", effort: "high")
      expect(result[:floor_reason]).to include("verb risk").and include("system_expose_service_publicly")
    end
  end
end
