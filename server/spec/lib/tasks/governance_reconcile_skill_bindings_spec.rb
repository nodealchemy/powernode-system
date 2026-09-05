# frozen_string_literal: true

require "rails_helper"
require "rake"

# HIER-P2G item 2 — the boot-time governance reconcile path re-materialises
# Ai::AgentSkill bindings from the SkillBindings registry, so an established
# install (db:seed is FIRST-BOOT ONLY) picks up an executor's re-binding
# without a seed run. Two entry points share the reconciler:
#
#   * `rails system:governance:reconcile` (operator-invoked)
#   * modules/powernode-hub-backend/rootfs/usr/local/bin/governance-reconcile.rb
#     (rails-start.sh runs it on EVERY boot, advisory, never fatal)
RSpec.describe "governance reconcile — skill bindings step" do
  before(:all) do
    glob = Rails.root.join("../extensions/system/server/app/services/system/ai/skills/**/*_executor.rb")
    Dir.glob(glob).each { |f| require_dependency f }
    Rails.application.load_tasks unless Rake::Task.task_defined?("system:governance:reconcile")
  end

  def load_seed!(file)
    silence_warnings do
      load Rails.root.join("..", "extensions", "system", "server", "db", "seeds", file)
    end
  end

  # The rake tasks print their report; keep it out of the spec output.
  def quietly
    original_out, original_err = $stdout, $stderr
    $stdout = StringIO.new
    $stderr = StringIO.new
    yield
  ensure
    $stdout, $stderr = original_out, original_err
  end

  let!(:account) { create(:account) }
  # The reconciler resolves a registration's agent by SOURCE KEY, never by
  # display name (a name is a label; renaming the agent must not orphan its
  # skills). A canonical seeded by AgentSetupHelpers carries that key, so the
  # fixture must too — without it the reconciler finds nobody to bind, the
  # `before` block's destroy! has no row to remove, and every example here
  # reads as a NoMethodError on nil instead of the drift it exists to catch.
  let!(:cve) do
    create(:ai_agent, :global, name: "CVE Responder", source_key: "cve-responder",
                               agent_type: "monitor", is_system: true)
  end
  let(:cve_slugs) do
    System::Ai::Skills::SkillBindings.discover.select { |e| e[:agent_key] == "cve-responder" }
                                     .map { |e| e[:skill_slug] }.uniq
  end

  # An ESTABLISHED install: seeded once, then one binding lost (an executor
  # re-bound after first boot looks exactly like this).
  before do
    %w[system_skills_seed.rb system_provisioning_skills_seed.rb system_dr_skills_seed.rb].each { |f| load_seed!(f) }
    System::Ai::Skills::SkillBindingsReconciler.new.reconcile!
    Ai::AgentSkill.where(ai_agent_id: cve.id).first.destroy!
    expect(cve.reload.skill_slugs.size).to eq(cve_slugs.size - 1)
  end

  it "rake system:governance:reconcile restores the lost binding" do
    expect { quietly { Rake::Task["system:governance:reconcile"].execute } }
      .to change { cve.reload.skill_slugs.size }.by(1)

    expect(cve.reload.skill_slugs).to match_array(cve_slugs)
  end

  it "rake system:governance:drift reports the missing binding read-only and exits 1" do
    expect { quietly { Rake::Task["system:governance:drift"].execute } }.to raise_error(SystemExit)

    expect(cve.reload.skill_slugs.size).to eq(cve_slugs.size - 1)
  end

  it "governance-reconcile.rb (the per-boot script) restores the lost binding and prints its summary line" do
    script = Rails.root.join("..", "extensions", "system", "modules", "powernode-hub-backend",
                             "rootfs", "usr", "local", "bin", "governance-reconcile.rb")

    expect { load script }
      .to output(/\[governance-reconcile\] skill-bindings upserted=1 removed=0 missing_skills=0/).to_stderr
      .and change { cve.reload.skill_slugs.size }.by(1)
  end
end
