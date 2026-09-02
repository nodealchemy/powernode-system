# frozen_string_literal: true

require "rails_helper"

# IMP-d4fc286b7ccf defect 1 — the extension's own convention (CLAUDE.md
# "New capability" §2) is that every skill needs BOTH an executor class AND a
# seeded `Ai::Skill` row. `System::Ai::Skills::SkillBindings.validate!` is the
# mechanical statement of that rule, and `system_skill_bindings_seed.rb:37`
# calls it UNRESCUED before creating any binding row.
#
# So a single missing `Ai::Skill` row does not merely hide one skill — it
# aborts the WHOLE bindings seed, leaving ZERO `Ai::AgentSkill` rows for every
# system agent. `fulfill_capability_request` (the end-to-end "purpose → node"
# orchestration) declares `binds_to "System Concierge", "Fleet Autonomy"` but
# had no seeded skill, so the agents that are supposed to reach it never got
# bound to anything at all.
#
# This pins the coverage invariant across the seed run AS db/seeds.rb ORDERS IT
# (skills seed → provisioning skills seed → bindings), which is the only order
# in which the invariant is meaningful — see load_skills_seeds! below.
RSpec.describe "system_skills_seed — SkillBindings coverage" do
  # Populate the registry the way system_skill_bindings_seed.rb does (in
  # production these autoload on reference; nothing has touched them here).
  # Same precedent as skill_bindings_no_core_agent_leak_spec.rb.
  before(:all) do
    glob = Rails.root.join("../extensions/system/server/app/services/system/ai/skills/**/*_executor.rb")
    Dir.glob(glob).each { |f| require_dependency f }
  end

  # The seeds key off `Account.first`.
  let!(:account) { create(:account) }

  # PRODUCTION ORDER. db/seeds.rb:50-52 runs system_skills_seed.rb, then
  # system_provisioning_skills_seed.rb, then the bindings seed — and the
  # coverage invariant is a property of that whole run, not of either file
  # alone. Six binds_to executors (provision_full_stack, deploy_app_code,
  # attach_storage, scale_project, relocate_workload,
  # configure_sdwan_for_project) are seeded by the PROVISIONING file; loading
  # only the first file here would falsely report them missing and tempt
  # someone into duplicating them (both files upsert by slug, so the later one
  # wins and the duplicate becomes dead content).
  #
  # `system_dr_skills_seed.rb` is the THIRD file in that run (see
  # SYSTEM_SEED_FILES in extensions/system/server/db/seeds.rb, which is the only
  # place seed ORDER is declared). It is loaded here for the same reason the
  # provisioning file is: the coverage invariant is a property of the whole run,
  # and omitting a seed that DOES exist reports its slugs as missing.
  def load_skills_seeds!
    silence_warnings do
      %w[system_skills_seed.rb system_provisioning_skills_seed.rb
         system_dr_skills_seed.rb].each do |file|
        load Rails.root.join("..", "extensions", "system", "server", "db", "seeds", file)
      end
    end
  end

  it "seeds an Ai::Skill row for every binds_to-registered executor" do
    load_skills_seeds!

    expect { ::System::Ai::Skills::SkillBindings.validate! }.not_to raise_error
  end

  it "leaves the provisioning-owned skills to the provisioning seed alone" do
    silence_warnings do
      load Rails.root.join("..", "extensions", "system", "server", "db", "seeds",
                           "system_skills_seed.rb")
    end

    # This file must NOT carry a copy of the six the provisioning seed owns —
    # a duplicate here is silently clobbered minutes later and rots.
    %w[
      system-provision-full-stack system-deploy-app-code system-attach-storage
      system-scale-project system-relocate-workload system-configure-sdwan-for-project
    ].each do |slug|
      expect(::Ai::Skill.find_by(slug: slug)).to be_nil,
        "#{slug} is seeded by system_provisioning_skills_seed.rb — remove the duplicate from system_skills_seed.rb"
    end
  end

  it "seeds the fulfillment orchestration chain (the unreachable end-to-end slice)" do
    load_skills_seeds!

    %w[
      system-fulfill-capability-request
      system-module-smoke-verify
      system-boot-image-drift-rollout
    ].each do |slug|
      expect(::Ai::Skill.find_by(slug: slug)).to be_present,
        "#{slug} has a binds_to executor but no seeded Ai::Skill row"
    end
  end

  it "binds fulfill_capability_request to both its declared agents" do
    load_skills_seeds!

    owners = ::System::Ai::Skills::SkillBindings.discover
      .select { |e| e[:skill_slug] == "system-fulfill-capability-request" }
      .map { |e| e[:agent_name] }

    expect(owners).to contain_exactly("System Concierge", "Fleet Autonomy")
  end

  it "is idempotent across re-runs" do
    load_skills_seeds!

    expect { load_skills_seeds! }.not_to change { ::Ai::Skill.where(is_system: true).count }
  end
end
