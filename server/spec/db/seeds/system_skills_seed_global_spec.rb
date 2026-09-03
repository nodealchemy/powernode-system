# frozen_string_literal: true

require "rails_helper"

# HIER-P2G — the canonical rule ("all official agents are canonical and
# seeded") extends to the skills they bind: a GLOBAL canonical agent cannot be
# made whole by ACCOUNT-scoped skill rows. The three skill catalog seeds of
# this extension used to key every Ai::Skill on `Account.first`, while the
# canonical Claude Code export (Ai::ClaudeExport::AgentSkeletonSync, canonical
# scope) reads GLOBAL skills only — so every committed skeleton showed 0 skills
# for every system agent, and the router's skill dimension saw a tenant's
# private rows. The seeds now mint GLOBAL canonicals (account_id nil,
# source_key = slug, is_system), the way core's db/seeds/ai_skills_seed.rb does,
# and convert an established install's account-scoped rows IN PLACE (id
# stable — every Ai::AgentSkill keeps pointing at the same row), never
# duplicating them and never touching an account's own override (a row with
# cloned_from_id set).
RSpec.describe "system skill catalog seeds — GLOBAL canonicals" do
  SKILL_CATALOG_SEEDS = %w[
    system_skills_seed.rb
    system_provisioning_skills_seed.rb
    system_dr_skills_seed.rb
  ].freeze

  # One slug from EACH catalog file, so a file that regresses to account
  # scoping fails on its own row rather than hiding behind the others.
  SAMPLE_SLUGS = %w[
    system-attribute-failure
    system-provision-full-stack
    system-provision-infrastructure
    system-promote-replica
  ].freeze

  def load_seed!(file)
    silence_warnings do
      load Rails.root.join("..", "extensions", "system", "server", "db", "seeds", file)
    end
  end

  def load_catalog!
    SKILL_CATALOG_SEEDS.each { |file| load_seed!(file) }
  end

  def system_rows
    Ai::Skill.where("metadata->>'author' = ?", "system_extension")
  end

  context "on a fresh install (no account exists yet)" do
    it "seeds every catalog skill GLOBAL, keyed on its source_key, without needing an account" do
      expect(Account.count).to eq(0)

      load_catalog!

      expect(system_rows.count).to be > 40
      SAMPLE_SLUGS.each do |slug|
        expect(Ai::Skill.global.find_by(slug: slug)).to be_present, "#{slug} was not seeded as a GLOBAL row"
      end
      expect(system_rows.where.not(account_id: nil)).to be_empty,
        "account-scoped rows: #{system_rows.where.not(account_id: nil).pluck(:slug).inspect}"
      system_rows.find_each do |skill|
        expect(skill.source_key).to eq(skill.slug), "#{skill.slug} has source_key #{skill.source_key.inspect}"
        expect(skill.is_system).to be(true), "#{skill.slug} is not is_system"
      end
    end
  end

  context "on an established install carrying the pre-P2G account-scoped rows" do
    let!(:account) { create(:account) }

    def legacy_row!(slug, name)
      create(:ai_skill, account: account, slug: slug, name: name, category: "devops",
                        is_system: true, metadata: { "author" => "system_extension" })
    end

    it "converts each row in place — same id, now global — and never inserts a second row" do
      legacy = SAMPLE_SLUGS.map { |slug| legacy_row!(slug, slug.titleize) }
      bound_agent = create(:ai_agent, :global, name: "Binding Holder", is_system: true)
      binding = create(:ai_agent_skill, agent: bound_agent, skill: legacy.first, is_active: true)

      load_catalog!

      legacy.each do |row|
        expect(Ai::Skill.where(slug: row.slug).count).to eq(1), "#{row.slug} was duplicated"
        row.reload
        expect(row.account_id).to be_nil, "#{row.slug} is still account-scoped"
        expect(row.source_key).to eq(row.slug)
        expect(row.is_system).to be(true)
      end
      # The binding survives the conversion because the id did.
      expect(binding.reload.ai_skill_id).to eq(legacy.first.id)
    end

    it "leaves an account's own override (cloned_from_id set) alone, even when it reuses the slug" do
      load_catalog!
      global = Ai::Skill.global.find_by!(slug: "system-attribute-failure")
      override = create(:ai_skill, account: account, slug: global.slug, name: "#{global.name} (tuned)",
                                   cloned_from: global, category: global.category)

      load_catalog!

      expect(override.reload.account_id).to eq(account.id)
      expect(override.cloned_from_id).to eq(global.id)
      expect(Ai::Skill.global.where(slug: global.slug).count).to eq(1)
    end

    it "mints a fresh global rather than adopting a clone when only clones carry the slug" do
      # The origin is gone (a global row an operator deleted); its clone must
      # not be promoted to canonical in its place — the clone is the account's
      # customisation, not the platform's default.
      orphan_clone = create(:ai_skill, account: account, slug: "system-attribute-failure",
                                       name: "Attribute Failure (tuned)", category: "devops")
      orphan_clone.update_columns(cloned_from_id: SecureRandom.uuid)

      load_catalog!

      expect(orphan_clone.reload.account_id).to eq(account.id)
      global = Ai::Skill.global.find_by(slug: "system-attribute-failure")
      expect(global).to be_present
      expect(global.id).not_to eq(orphan_clone.id)
    end
  end

  it "is idempotent across re-runs" do
    load_catalog!

    expect { load_catalog! }.not_to change { [ Ai::Skill.count, Ai::Skill.global.count ] }
  end

  it "stamps each executor-backed skill with its executor's action category so the canonical export " \
     "can derive the agent's policy DOMAINS from global rows alone (Ai::ClaudeExport::PolicyDomains)" do
    load_catalog!

    skill = Ai::Skill.global.find_by!(slug: "system-attribute-failure")
    expect(skill.metadata["action_category"]).to eq(System::Ai::Skills::AttributeFailureExecutor.action_category)

    # The entry skill has no executor and therefore no category.
    entry = Ai::Skill.global.find_by!(slug: "system-provision-infrastructure")
    expect(entry.metadata).not_to have_key("action_category")
  end

  # The BLOCKER the review caught: a GLOBAL Ai::Skill never fires the inline
  # per-account knowledge-graph hook (Ai::Skill#sync_to_knowledge_graph returns
  # early on a nil account_id — a node requires an account), and core's
  # compensating bulk sync at the tail of db/seeds/ai_skills_seed.rb runs
  # BEFORE any extension seed. So converting the catalog to global rows would
  # have stripped every system skill of its node, and both
  # `platform.discover_skills` and Ai::ConciergeRouter#discover_relevant_skills
  # read skill NODES (account.ai_knowledge_graph_nodes.skill_nodes, via
  # Ai::SkillGraph::TraversalService), never the ai_skills table.
  describe "knowledge-graph visibility — db/seeds/system_skill_graph_sync.rb" do
    let!(:account) { create(:account) }

    it "mints each account's own node copy for the seeded globals, which the catalog seeds alone do not" do
      load_catalog!
      skill = Ai::Skill.global.find_by!(slug: "system-attribute-failure")
      expect(Ai::KnowledgeGraphNode.where(ai_skill_id: skill.id, account_id: account.id, status: "active"))
        .to be_empty, "the inline hook is not expected to fire for a global row"

      load_seed!("system_skill_graph_sync.rb")

      node = Ai::KnowledgeGraphNode.find_by(ai_skill_id: skill.id, account_id: account.id, status: "active")
      expect(node).to be_present, "the seeded global system skill has no knowledge-graph node"
      expect(node.entity_type).to eq("skill")
      # The predicate the consumers actually run.
      expect(account.ai_knowledge_graph_nodes.skill_nodes.active.pluck(:ai_skill_id)).to include(skill.id)
    end

    it "is listed in the seed orchestrator so `rails db:seed` runs it" do
      orchestrator = Rails.root.join("..", "extensions", "system", "server", "db", "seeds.rb").read
      expect(orchestrator).to include("system_skill_graph_sync.rb")
    end
  end

  it "still lists every global for an account through the override-aware scope the API and " \
     "platform.list_skills read (GloballyScopable.for_account)" do
    account = create(:account)
    load_catalog!

    visible = Ai::Skill.for_account(account.id).pluck(:slug)
    SAMPLE_SLUGS.each { |slug| expect(visible).to include(slug) }
  end
end
