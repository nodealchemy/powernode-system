# frozen_string_literal: true

# Seeds Ai::AgentSkill bindings from the SkillBindings registry — the SOLE
# source of truth for agent → skill bindings in the system extension.
#
# The body lives in System::Ai::Skills::SkillBindingsReconciler (HIER-P2G):
#   1. Walk `System::Ai::Skills::SkillBindings.discover` (every executor
#      registered via `binds_to` in its class body)
#   2. For each (skill_slug, agent_name) tuple, find_or_initialize the
#      matching Ai::AgentSkill row — GLOBAL skill to GLOBAL agent
#   3. Destroy any registry-agent Ai::AgentSkill row that is NOT in the
#      registry (drift correction — keeps DB state aligned with code state)
#
# The same reconciler runs LENIENTLY on every boot (governance-reconcile.rb /
# `rails system:governance:reconcile`), because `db:seed` is first-boot only
# and a binding added after an install's first boot would otherwise never
# reach it. Here, at seed time, it is STRICT: a registered skill with no
# Ai::Skill row (seeds run out of order) aborts before any binding is written.
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

result = System::Ai::Skills::SkillBindingsReconciler.new(strict: true).reconcile!

puts "    Registry has #{result.registered} (skill, agent) binding declarations"
result.unknown_agents.each do |name|
  puts "    ⚠️  agent '#{name}' not seeded — its bindings skipped; seed the agent first"
end
result.missing_skills.each do |slug|
  puts "    ⚠️  skill '#{slug}' has no GLOBAL Ai::Skill row — its binding skipped"
end
puts "    ⚠️  SkillBindings registry loaded EMPTY — drift correction skipped" if result.registry_empty
puts "    ✅ Upserted #{result.upserted} new/changed binding(s)"
puts "    🧹 Cleaned #{result.removed} stale Ai::AgentSkill row(s) not in registry" if result.removed.positive?

# Sanity log: bindings per registry-known agent
result.bound_by_agent.each do |name, count|
  puts "    • #{name.ljust(28)} → #{count} skill(s)"
end

puts "  ✅ Skill bindings seed complete."
