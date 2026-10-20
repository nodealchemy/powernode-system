# frozen_string_literal: true

require "rails_helper"

# System extension capability skills: seeded by this extension (only when it is
# enabled), gated by core's Ai::Skills::SeedGate for this owner, idempotent, and
# discoverable for the fleet / infrastructure / delivery eval tasks — including
# the v1 eval set — against core's capability skills and the legacy rows.
RSpec.describe "system extension capability skills", type: :seed do
  let!(:account) { create(:account) }
  let(:ext_dir) { Rails.root.join("../extensions/system/server/db/seeds").cleanpath }
  let(:core_seed) { Rails.root.join("db", "seeds", "ai_capability_skills_seed.rb") }
  let(:ext_seed) { ext_dir.join("system_capability_skills_seed.rb") }
  let(:entries) { Ai::Skills::CapabilitySeeder.load_entries(ext_dir.join("capability_skills")) }
  let(:core_entries) { Ai::Skills::CapabilitySeeder.load_entries(Rails.root.join("db", "seeds", "capability_skills")) }

  def system_rows
    Ai::Skill.global.where("metadata->>'owner_repo' = ?", "extensions/system").order(:slug)
  end

  describe "seeding" do
    before { seed_with_baseline!(core_seed, ext_seed) }

    it "writes every authored skill as a global, contract-conforming row owned by this extension" do
      expect(system_rows.pluck(:slug)).to match_array(entries.map { |e| e["slug"] })
      system_rows.each { |skill| expect(skill).to be_valid, -> { "#{skill.slug}: #{skill.errors.full_messages.join('; ')}" } }
    end

    it "is idempotent" do
      state = -> { [ system_rows.map { |s| s.attributes.except("updated_at", "created_at") }, Ai::SkillComposition.count, Ai::KnowledgeGraphEdge.count ] }
      before_state = state.call
      load ext_seed
      expect(state.call).to eq(before_state)
    end

    it "records the delivery composite's components, including core skills, in order" do
      composite = system_rows.find(&:is_composite)
      expect(composite).to be_present
      components = Ai::SkillComposition.for_composite(composite.id).in_order.map { |c| c.component_skill.slug }
      expect(components).to eq(composite.metadata.dig("relations", "composes"))
    end

    # Positive, not vacuous: every verb is either this extension's (system_*)
    # or a core verb (no extension's prefix at all) — whether or not any other
    # extension happens to be loaded in this run.
    it "names only this extension's verbs and core verbs" do
      prefixes = (Powernode::ExtensionRegistry.slugs.map(&:to_s) | %w[system]).map { |s| "#{s.tr('-', '_')}_" }
      system_rows.each do |skill|
        Array(skill.metadata.dig("manifest", "verbs")).each do |verb|
          owner = prefixes.find { |p| verb.start_with?(p) }
          expect(owner.nil? || owner == "system_").to be(true), "#{skill.slug} names #{verb}, owned by #{owner}"
        end
      end
    end

    # First boot: the provider is usually not ready, so :auto falls back to the
    # lexical space; the authored batch must pass the gate there too.
    it "passes the gate in the lexical space (the first-boot path)" do
      gate = Ai::Skills::SeedGate.new(owner_repo: "extensions/system", embedder: :lexical)
      normalized = entries.map { |raw| Ai::Skills::CapabilitySeeder.normalize(raw, "extensions/system") }
      expect(gate.violations(normalized)).to eq([])
    end
  end

  describe "when core's capability skills are missing" do
    after { Ai::Skills::CapabilitySeeder.reset_failures! }

    it "fails loudly: the batch is rejected, recorded before any orchestrator rescue, and nothing is written" do
      Ai::Skills::CapabilitySeeder.reset_failures!
      expect { seed_with_baseline!(ext_seed) }.to raise_error(Ai::Skills::SeedGate::GateError, /is not a seeded capability skill/)
                                              .and output(/SYSTEM CAPABILITY SKILL SEED FAILED/).to_stdout
      expect(system_rows.count).to eq(0)
      expect(Ai::Skills::CapabilitySeeder.failures.map { |f| f[:owner_repo] }).to eq(%w[extensions/system])
    end
  end

  describe "discovery evals (recorded real embeddings)" do
    let(:engineer_ceiling) { Ai::Skills::Contract::CORE_DOMAINS - %w[front-door] }
    let(:platform_dev) { platform_dev_slugs(core_entries) }

    # Real provider embeddings replayed from the recorded fixture (see
    # CapabilityDiscoveryHelpers#use_recorded_skill_embeddings!), every
    # capability batch present. Production numbers with the legacy rows
    # competing and the real cut-off: `rails skills:eval:discovery`.
    before do
      use_recorded_skill_embeddings!
      seed_with_baseline!(core_seed, ext_seed)
    end

    def top(task, **facets)
      discovered_slugs(account, task, **facets).first(CapabilityDiscoveryHelpers::TOP_K)
    end

    it "selects each skill (core's and this extension's) for its own positive evals and not for its negative ones" do
      # Core's evals and this extension's, with both batches competing.
      scored = core_entries + entries
      expect_misses_within_ledger(eval_misses(account, scored), scored, owner: "extensions/system")
    end

    # The six v1 eval tasks (two returned nothing on the live baseline).
    {
      "Work a dev-improve task that adds a migration and a spec" => %w[dev-loop-execution rails-backend-conventions test-authoring],
      "Review this campaign increment against its acceptance criteria" => %w[acceptance-criteria-review campaign-increment-protocol],
      "Provision a VM with attached storage for a new project" => %w[fleet-provisioning-entry storage-operations fleet-capacity-operations],
      "Help me onboard: I want to set up Powernode for my team" => %w[front-door-triage provisioning-brief-capture],
      "Rotate the WireGuard key for an SD-WAN peer" => %w[sdwan-operations]
    }.each do |task, owners|
      it "v1: returns an owning skill for #{task.inspect}" do
        expect(top(task) & owners).not_to be_empty, "got #{top(task).inspect}"
      end
    end

    # User-project work: the right extension or generic skill, never a platform-dev skill first.
    {
      "Expose service X publicly with a Let's Encrypt cert behind the reverse proxy" => %w[service-exposure acme-certificate-lifecycle],
      "Join two SD-WAN sites" => %w[sdwan-operations topology-composition],
      "Federate with a partner" => %w[sdwan-federation],
      "Roll back the customer's last deploy" => %w[runtime-operations],
      "Patch a CVE in a running customer service" => %w[cve-response],
      "Probe platform health and report what is down or degraded" => %w[platform-health-probe],
      "Handle a repeated fleet lane signal" => %w[fleet-signal-handling]
    }.each do |task, owners|
      it "selects #{owners.join(' or ')} for #{task.inspect}" do
        ranked = top(task)
        expect(ranked & owners).not_to be_empty, "got #{ranked.inspect}"
        expect(platform_dev).not_to include(ranked.first)
      end
    end

    it "assembles the delivery composite with exposure, ACME and runtime for a production deploy" do
      ranked = discovered_slugs(account, "Deploy the customer's Node app to production with a public HTTPS endpoint").first(6)
      expect(ranked).to include("project-production-delivery")
      expect(ranked & %w[service-exposure acme-certificate-lifecycle runtime-operations]).not_to be_empty
    end

    it "gives the engineer the hand-off, not the deploy skills, for \"deploy my app\"" do
      ranked = top("Deploy my app", domains: engineer_ceiling)
      expect(ranked.first).to eq("deployment-handoff")
      expect(ranked & entries.map { |e| e["slug"] }).to be_empty
    end
  end
end
