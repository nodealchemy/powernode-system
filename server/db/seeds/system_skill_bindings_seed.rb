# frozen_string_literal: true

# Seeds Ai::AgentSkill bindings from the SkillBindings registry — the SOLE
# source of truth for agent → skill bindings in the system extension.
#
# How it works:
#   1. Walk `System::Ai::Skills::SkillBindings.discover` (every executor
#      registered via `binds_to` in its class body)
#   2. For each (skill_slug, agent_name) tuple, find_or_initialize the
#      matching Ai::AgentSkill row
#   3. Destroy any system-agent Ai::AgentSkill row that is NOT in the
#      registry (drift correction — keeps DB state aligned with code state)
#
# This is the clean-break replacement for the old dual-mode setup, where
# bindings lived in BOTH `system_skills_seed.rb:730-851` (hardcoded slug
# arrays) AND scattered SkillBindings.register calls at the bottom of
# executor files. With BaseSkillExecutor + `binds_to` DSL, every executor
# declares its bindings at class scope, and this seed materializes them.
#
# Invocation (part of regular seeding):
#   cd server && rails db:seed
#
# Or in isolation:
#   cd server && rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/system_skill_bindings_seed.rb')"

puts "\n  Seeding agent ↔ skill bindings from SkillBindings registry..."

# Force the executor files to load so each calls `binds_to` and populates
# the registry. In production runtime they autoload on reference; in seed
# context nothing has touched them yet.
exec_glob = Rails.root.join("../extensions/system/server/app/services/system/ai/skills/**/*_executor.rb")
Dir.glob(exec_glob).each { |f| require_dependency f }

# Validate that every registered skill_slug has a matching Ai::Skill row.
# Raises noisily if seeds were run out of order (skill rows missing).
System::Ai::Skills::SkillBindings.validate!

registrations = System::Ai::Skills::SkillBindings.discover
puts "    Registry has #{registrations.size} (skill, agent) binding declarations"

# Build desired (agent_id, skill_id) pairs.
desired_pairs = []
unknown_agents = Hash.new(0)
seen_executors = Set.new

registrations.each do |entry|
  seen_executors << entry[:executor]
  agent = ::Ai::Agent.find_by(name: entry[:agent_name])
  unless agent
    unknown_agents[entry[:agent_name]] += 1
    next
  end

  skill = ::Ai::Skill.find_by(slug: entry[:skill_slug])
  unless skill
    # Should have been caught by SkillBindings.validate! above. Defensive raise.
    raise "Ai::Skill row missing for slug #{entry[:skill_slug]} — abort seed"
  end

  desired_pairs << [ agent.id, skill.id ]
end

if unknown_agents.any?
  unknown_agents.each do |name, count|
    puts "    ⚠️  agent '#{name}' not seeded — skipping #{count} binding(s); seed the agent first"
  end
end

# Upsert desired bindings.
upserted = 0
desired_pairs.each_with_index do |(agent_id, skill_id), i|
  binding = ::Ai::AgentSkill.find_or_initialize_by(
    ai_agent_id: agent_id, ai_skill_id: skill_id
  )
  binding.assign_attributes(priority: 100 + i, is_active: true)
  if binding.new_record? || binding.changed?
    binding.save!
    upserted += 1
  end
end
puts "    ✅ Upserted #{upserted} new/changed binding(s) (#{desired_pairs.size} total in registry)"

# Drift correction: destroy Ai::AgentSkill rows for the agents the registry
# knows about, where the (agent, skill) pair is not in the registry. We scope
# by registry-named agents rather than a global "is_system" flag (no such
# column on ai_agents) so we don't touch bindings for agents outside the
# system extension's domain.
registry_agent_names = registrations.map { |e| e[:agent_name] }.uniq
registry_agent_ids   = ::Ai::Agent.where(name: registry_agent_names).pluck(:id)
desired_set          = desired_pairs.to_set

stale = ::Ai::AgentSkill
  .where(ai_agent_id: registry_agent_ids)
  .reject { |row| desired_set.include?([ row.ai_agent_id, row.ai_skill_id ]) }

if stale.any?
  stale_count = stale.size
  ::Ai::AgentSkill.where(id: stale.map(&:id)).destroy_all
  puts "    🧹 Cleaned #{stale_count} stale Ai::AgentSkill row(s) not in registry"
end

# Sanity log: bindings per registry-known agent
::Ai::Agent.where(name: registry_agent_names).order(:name).each do |agent|
  count = ::Ai::AgentSkill.where(ai_agent_id: agent.id).count
  puts "    • #{agent.name.ljust(28)} → #{count} skill(s)"
end

puts "  ✅ Skill bindings seed complete (#{seen_executors.size} executors registered)."
