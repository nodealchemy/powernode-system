# frozen_string_literal: true

# Discovery-based skill binding seed (audit plan P3.3).
#
# Walks the SkillBindings registry (populated at load time by executors
# calling `System::Ai::Skills::SkillBindings.register(self, agents: [...])`)
# and binds each (agent, skill) pair via `Ai::AgentSkill.find_or_initialize_by`.
#
# Dual-mode for one release: the existing hardcoded blocks in
# `system_concierge_agent.rb`, `system_runtime_manager_agent.rb`,
# `system_cve_responder_agent.rb`, etc. still run and bind the same pairs.
# `find_or_initialize_by` makes both paths idempotent — running both is
# safe and produces no duplicates.
#
# After all 40 executors have added `SkillBindings.register` calls, the
# hardcoded blocks can be deleted (release N+1). Until then this seed
# is purely additive — it only fills in bindings that the registry knows
# about, leaving the rest to the existing seeds.
#
# Invoke (as part of regular seeding):
#   cd server && rails db:seed
#
# Or in isolation:
#   cd server && rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/system_skill_bindings_seed.rb')"

# Eager-load all skill executor files so their SkillBindings.register
# calls fire. In production seeds this happens via Rails.application
# .eager_load!; for explicit invocation we walk the directory.
exec_glob = Rails.root.join("../extensions/system/server/app/services/system/ai/skills/**/*_executor.rb")
Dir.glob(exec_glob).each { |f| require_dependency f }

puts "\n  📎 Discovery-based skill binding seed (P3.3)…"
registrations = ::System::Ai::Skills::SkillBindings.discover
puts "  Registry has #{registrations.size} executor(s) declaring bindings"

account = ::Account.first or abort("  ❌ No account in DB — seed an Account first")

bound = 0
missing_skill = 0
missing_agent = 0

registrations.each do |entry|
  skill = ::Ai::Skill.find_by(slug: entry[:skill_slug])
  unless skill
    puts "  ⚠ skill not seeded yet: #{entry[:skill_slug]} (from #{entry[:executor]})"
    missing_skill += 1
    next
  end

  entry[:agents].each do |agent_name|
    agent = account.ai_agents.find_by(name: agent_name)
    unless agent
      puts "  ⚠ agent not seeded yet: #{agent_name} (for skill #{entry[:skill_slug]})"
      missing_agent += 1
      next
    end

    binding = ::Ai::AgentSkill.find_or_initialize_by(
      ai_agent_id: agent.id, ai_skill_id: skill.id
    )
    if binding.persisted?
      # already bound by hardcoded seed; refresh active flag in case the
      # operator toggled it off.
      binding.update!(is_active: true) unless binding.is_active?
    else
      binding.assign_attributes(priority: 100, is_active: true)
      binding.save!
    end
    bound += 1
  end
end

puts "  ✅ Bound #{bound} (agent, skill) pair(s) via discovery"
if missing_skill > 0 || missing_agent > 0
  puts "  ⚠ Skipped: missing_skill=#{missing_skill} missing_agent=#{missing_agent}"
  puts "  This is OK during dual-mode: hardcoded seeds will cover them."
end
