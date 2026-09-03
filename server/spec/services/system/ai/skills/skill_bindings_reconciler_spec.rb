# frozen_string_literal: true

require "rails_helper"

# HIER-P2G — the SkillBindings registry (every executor's `binds_to`) is the
# sole source of truth for agent → skill bindings, and this reconciler is the
# ONE writer that materialises it as Ai::AgentSkill rows. Two callers:
#
#   * system_skill_bindings_seed.rb (first boot, strict: a registered skill
#     with no Ai::Skill row aborts the seed, as it always has);
#   * the boot-time governance reconcile path (governance-reconcile.rb and
#     `rails system:governance:reconcile`), lenient: `db:seed` is FIRST-BOOT
#     ONLY, so a binding added to an executor after an install's first boot
#     never reached that install — HIER-P2B noted no boot-time reconciler
#     re-materialised Ai::AgentSkill. At boot a missing skill row is reported
#     and skipped, never raised.
#
# Ai::AgentSkill carries NO account column (confirmed: schema has
# ai_agent_id + ai_skill_id + priority + is_active only), so a binding joins a
# GLOBAL agent to a GLOBAL skill and is the same on every install.
RSpec.describe System::Ai::Skills::SkillBindingsReconciler do
  before(:all) do
    glob = Rails.root.join("../extensions/system/server/app/services/system/ai/skills/**/*_executor.rb")
    Dir.glob(glob).each { |f| require_dependency f }
  end

  def load_seed!(file)
    silence_warnings do
      load Rails.root.join("..", "extensions", "system", "server", "db", "seeds", file)
    end
  end

  def seed_skill_catalog!
    %w[system_skills_seed.rb system_provisioning_skills_seed.rb system_dr_skills_seed.rb].each { |f| load_seed!(f) }
  end

  def canonical(name, agent_type: "monitor")
    create(:ai_agent, :global, name: name, agent_type: agent_type, is_system: true)
  end

  let(:registry) { System::Ai::Skills::SkillBindings.discover }
  let(:cve_slugs) { registry.select { |e| e[:agent_name] == "CVE Responder" }.map { |e| e[:skill_slug] }.uniq }

  subject(:reconciler) { described_class.new }

  describe "#reconcile!" do
    it "binds every registered (skill, agent) pair as GLOBAL skill → GLOBAL agent" do
      seed_skill_catalog!
      cve = canonical("CVE Responder")

      result = reconciler.reconcile!

      expect(cve.reload.skill_slugs).to match_array(cve_slugs)
      expect(Ai::AgentSkill.joins(:skill).where(ai_agent_id: cve.id).where.not(ai_skills: { account_id: nil })).to be_empty
      expect(result.upserted).to be >= cve_slugs.size
      expect(result.bound_by_agent["CVE Responder"]).to eq(cve_slugs.size)
    end

    it "binds the GLOBAL skill, never an account override reusing its slug" do
      seed_skill_catalog!
      cve = canonical("CVE Responder")
      global = Ai::Skill.global.find_by!(slug: cve_slugs.first)
      account = create(:account)
      override = create(:ai_skill, account: account, slug: global.slug, name: "#{global.name} (tuned)",
                                   cloned_from: global, category: global.category)

      reconciler.reconcile!

      bound_ids = Ai::AgentSkill.where(ai_agent_id: cve.id).pluck(:ai_skill_id)
      expect(bound_ids).to include(global.id)
      expect(bound_ids).not_to include(override.id)
    end

    it "keeps the provisioning entry skill bound to the System Concierge (no executor registers it)" do
      seed_skill_catalog!
      concierge = canonical("System Concierge", agent_type: "assistant")

      reconciler.reconcile!

      expect(concierge.reload.skill_slugs).to include("system-provision-infrastructure")
    end

    it "removes a binding the registry no longer declares (drift), on registry agents only" do
      seed_skill_catalog!
      cve = canonical("CVE Responder")
      outsider = canonical("Tenant Helper", agent_type: "assistant")
      stray_skill = Ai::Skill.global.find_by!(slug: "system-promote-replica")
      create(:ai_agent_skill, agent: cve, skill: stray_skill, is_active: true)
      kept = create(:ai_agent_skill, agent: outsider, skill: stray_skill, is_active: true)

      result = reconciler.reconcile!

      expect(cve.reload.skill_slugs).not_to include("system-promote-replica")
      expect(result.removed).to eq(1)
      expect(Ai::AgentSkill.exists?(kept.id)).to be(true)
    end

    it "is idempotent: a second run changes nothing" do
      seed_skill_catalog!
      canonical("CVE Responder")
      reconciler.reconcile!

      again = described_class.new.reconcile!

      expect(again.upserted).to eq(0)
      expect(again.removed).to eq(0)
      expect(again.changed?).to be(false)
    end

    it "re-materialises a binding an established install lost, without a seed run" do
      seed_skill_catalog!
      cve = canonical("CVE Responder")
      reconciler.reconcile!
      Ai::AgentSkill.where(ai_agent_id: cve.id).first.destroy!

      result = described_class.new.reconcile!

      expect(result.upserted).to eq(1)
      expect(cve.reload.skill_slugs).to match_array(cve_slugs)
    end

    it "reports agents the registry names that are not seeded, without failing" do
      seed_skill_catalog!

      result = reconciler.reconcile!

      expect(result.unknown_agents).to include("CVE Responder")
      expect(result.upserted).to eq(0)
    end

    context "strictness about a registered skill with no Ai::Skill row" do
      it "raises in strict mode (the seed's contract — abort before any partial binding state)" do
        canonical("CVE Responder")

        expect { described_class.new(strict: true).reconcile! }.to raise_error(/SkillBindings.validate! failed/)
        expect(Ai::AgentSkill.count).to eq(0)
      end

      # The gate must be the RESOLVER's scope. SkillBindings.validate! asks
      # `Ai::Skill.exists?(slug:)` UNSCOPED, so a slug surviving only as a
      # pre-P2G account row passes it — and the resolver (Ai::Skill.global)
      # would then skip the binding silently, where the seed it replaced
      # raised. Strict mode raises on the resolver's own miss.
      it "raises in strict mode when the slug exists only ACCOUNT-scoped, and writes nothing" do
        seed_skill_catalog!
        canonical("CVE Responder")
        account = create(:account)
        stranded = Ai::Skill.global.find_by!(slug: cve_slugs.first)
        stranded.update_columns(account_id: account.id)

        expect { described_class.new(strict: true).reconcile! }
          .to raise_error(/no GLOBAL Ai::Skill row.*#{Regexp.escape(cve_slugs.first)}/m)
        expect(Ai::AgentSkill.count).to eq(0)
      end

      it "skips and reports the missing rows in lenient (boot) mode, binding everything else" do
        seed_skill_catalog!
        cve = canonical("CVE Responder")
        missing = Ai::Skill.global.find_by!(slug: cve_slugs.first)
        missing.agent_skills.destroy_all
        missing.destroy!

        result = described_class.new(strict: false).reconcile!

        expect(result.missing_skills).to include(cve_slugs.first)
        expect(cve.reload.skill_slugs).to match_array(cve_slugs - [ cve_slugs.first ])
      end
    end
  end

  # An EMPTY registry is always a load failure (#load_executors! globs a path
  # that need not resolve on a deployed layout), never an "unbind everything"
  # instruction — and the boot caller runs the drift deletion behind a
  # non-fatal rescue, so an unfloored wipe would be one warn line in the
  # journal. ENTRY_SKILL_BINDINGS alone keeps System Concierge in scope.
  describe "the empty-registry floor" do
    it "skips drift deletion entirely and reports it, rather than unbinding every registry agent" do
      seed_skill_catalog!
      concierge = canonical("System Concierge", agent_type: "assistant")
      reconciler.reconcile!
      before_slugs = concierge.reload.skill_slugs
      expect(before_slugs.size).to be > 1

      allow(System::Ai::Skills::SkillBindings).to receive(:discover).and_return([])
      result = described_class.new.reconcile!

      expect(result.registry_empty).to be(true)
      expect(result.removed).to eq(0)
      expect(concierge.reload.skill_slugs).to match_array(before_slugs)
    end
  end

  describe "#drift" do
    it "is read-only: names the missing and stale pairs and writes nothing" do
      seed_skill_catalog!
      cve = canonical("CVE Responder")
      stray_skill = Ai::Skill.global.find_by!(slug: "system-promote-replica")
      create(:ai_agent_skill, agent: cve, skill: stray_skill, is_active: true)

      report = nil
      expect { report = reconciler.drift }.not_to change { Ai::AgentSkill.count }

      expect(report.missing.size).to eq(cve_slugs.size)
      expect(report.stale).to eq([ "CVE Responder → system-promote-replica" ])
      expect(report.drifted?).to be(true)
    end
  end

  describe "the seed wrapper" do
    it "delegates to the reconciler in strict mode" do
      seed_skill_catalog!
      cve = canonical("CVE Responder")

      load_seed!("system_skill_bindings_seed.rb")

      expect(cve.reload.skill_slugs).to match_array(cve_slugs)
    end
  end
end
