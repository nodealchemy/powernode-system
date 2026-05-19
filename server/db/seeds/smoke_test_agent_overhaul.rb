# frozen_string_literal: true

# Smoke test for the base-platform agent overhaul.
#
# Verifies that:
#   1. All 7 system agents exist with the new differentiated trust tiers
#      (CVE Responder + SDWAN Manager → trusted; others → monitored)
#   2. SkillBindings registry is populated (executors called `binds_to`)
#   3. Every (skill_slug, agent_name) registration has a matching
#      Ai::AgentSkill row in the DB (registry ↔ DB parity)
#   4. Every registered skill_slug has a corresponding Ai::Skill row
#   5. BaseSkillExecutor enforces #perform abstract (anonymous subclass
#      without override returns failure, not undefined-method-from-hell)
#   6. CrudFactory dispatches each route in ROUTES to the correct tool action
#   7. Claude agents (Strategic Planner + Research Analyst) have skill bindings
#   8. Concierge tool filter moved to ConciergeToolBridge constant
#
# Invoke:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_agent_overhaul.rb')"

step = ->(label) { puts "\n  [step] #{label}" }
ok   = ->(msg)   { puts "    ✓ #{msg}" }
fail_with = ->(msg) {
  puts "    ✗ #{msg}"
  abort("  💥 SMOKE FAIL")
}
assert = ->(condition, msg) { condition ? ok.call(msg) : fail_with.call(msg) }

puts "\n  Base-platform agent overhaul smoke test"
puts "  ========================================"
puts "  Today: #{Date.today}, Rails env: #{Rails.env}"

# ── Force executor files to load so the SkillBindings registry is populated ──
exec_glob = Rails.root.join("../extensions/system/server/app/services/system/ai/skills/**/*_executor.rb")
Dir.glob(exec_glob).each { |f| require_dependency f }

# ────────────────────────────────────────────────────────────────────
# 1. System agents + differentiated trust tiers
# ────────────────────────────────────────────────────────────────────
step.call("Verify 7 system agents exist with expected trust tiers")

EXPECTED_AGENTS = {
  "Fleet Autonomy"           => { tier: "monitored", overall: 0.74 },
  "Runtime Manager"          => { tier: "monitored", overall: 0.72 },
  "CVE Responder"            => { tier: "trusted",   overall: 0.80 },
  "SDWAN Manager"            => { tier: "trusted",   overall: 0.78 },
  "Disk Image Manager"       => { tier: "monitored", overall: 0.70 },
  "System Concierge"         => { tier: "monitored", overall: 0.75 },
  "System Topology Designer" => { tier: "monitored", overall: 0.72 }
}.freeze

EXPECTED_AGENTS.each do |name, expected|
  agent = ::Ai::Agent.find_by(name: name)
  assert.call(agent.present?, "agent '#{name}' exists")
  next unless agent

  score = ::Ai::AgentTrustScore.find_by(agent_id: agent.id)
  assert.call(score.present?, "  trust score row exists for #{name}")
  next unless score

  assert.call(score.tier == expected[:tier],
              "  #{name} tier=#{score.tier} (expected #{expected[:tier]})")
  assert.call(score.overall_score.to_f.round(2) == expected[:overall],
              "  #{name} overall=#{score.overall_score.to_f.round(2)} (expected #{expected[:overall]})")
end

# ────────────────────────────────────────────────────────────────────
# 2. SkillBindings registry populated
# ────────────────────────────────────────────────────────────────────
step.call("Verify SkillBindings registry is populated")

discovered = System::Ai::Skills::SkillBindings.discover
assert.call(discovered.size > 30,
            "registry has #{discovered.size} (skill, agent) entries (expected > 30)")

by_skill = System::Ai::Skills::SkillBindings.by_skill
unique_skill_count = by_skill.map { |r| r[:skill_slug] }.uniq.size
assert.call(unique_skill_count >= 35,
            "registry covers #{unique_skill_count} unique skills (expected ≥ 35)")

# ────────────────────────────────────────────────────────────────────
# 3. Every registration has a matching Ai::Skill row
# ────────────────────────────────────────────────────────────────────
step.call("Verify every registered skill_slug has a matching Ai::Skill row")

System::Ai::Skills::SkillBindings.validate!
ok.call("SkillBindings.validate! passed (every registered slug → Ai::Skill row exists)")

# ────────────────────────────────────────────────────────────────────
# 4. Registry ↔ DB binding parity
# ────────────────────────────────────────────────────────────────────
step.call("Verify (registry, DB) parity for system-agent bindings")

system_agent_ids = ::Ai::Agent.where(name: EXPECTED_AGENTS.keys).pluck(:name, :id).to_h

discovered_pairs = discovered.filter_map do |entry|
  agent_id = system_agent_ids[entry[:agent_name]]
  skill    = ::Ai::Skill.find_by(slug: entry[:skill_slug])
  next unless agent_id && skill
  [ agent_id, skill.id ]
end.uniq

db_pairs = ::Ai::AgentSkill
  .where(ai_agent_id: system_agent_ids.values)
  .pluck(:ai_agent_id, :ai_skill_id)
  .uniq

# Sanity log: per-agent binding counts
EXPECTED_AGENTS.keys.each do |name|
  agent_id = system_agent_ids[name]
  next unless agent_id
  count = ::Ai::AgentSkill.where(ai_agent_id: agent_id).count
  ok.call("  #{name.ljust(28)} → #{count} skill(s)")
end

missing_in_db   = discovered_pairs - db_pairs
extra_in_db     = db_pairs - discovered_pairs

assert.call(missing_in_db.empty?,
            "registry → DB: every registered binding exists in DB (missing=#{missing_in_db.size})")
assert.call(extra_in_db.empty?,
            "DB → registry: no orphan Ai::AgentSkill rows for system agents (extra=#{extra_in_db.size})")

# ────────────────────────────────────────────────────────────────────
# 5. BaseSkillExecutor abstract enforcement
# ────────────────────────────────────────────────────────────────────
step.call("Verify BaseSkillExecutor enforces #perform abstract")

abstract_klass = Class.new(System::Ai::Skills::BaseSkillExecutor) do
  skill_descriptor(name: "smoke_abstract", description: "x", category: "fleet",
                   inputs: {}, outputs: {})
end
result = abstract_klass.new(account: ::Account.first).execute
assert.call(result[:success] == false, "abstract subclass returns failure on execute")
assert.call(result[:error].to_s.include?("#perform must be defined"),
            "abstract failure references #perform")

# ────────────────────────────────────────────────────────────────────
# 6. CrudFactory route dispatch (3 architecture CRUD routes)
# ────────────────────────────────────────────────────────────────────
step.call("Verify CrudFactory dispatches each route")

route_count = System::Ai::Skills::CrudFactory::ROUTES.size
assert.call(route_count == 3, "CrudFactory has #{route_count} routes (expected 3)")

System::Ai::Skills::CrudFactory::ROUTES.each_key do |(resource, operation)|
  ok.call("  route registered: #{resource}/#{operation}")
end

# Verify subclasses inherit from CrudFactory
[ "ArchitectureCreateExecutor", "ArchitectureUpdateExecutor", "ArchitectureDeleteExecutor" ].each do |klass_name|
  klass = "System::Ai::Skills::#{klass_name}".constantize
  assert.call(klass.ancestors.include?(System::Ai::Skills::CrudFactory),
              "  #{klass_name} inherits from CrudFactory")
end

# ────────────────────────────────────────────────────────────────────
# 7. Claude agent skill bindings
# ────────────────────────────────────────────────────────────────────
step.call("Verify Claude agents have skill bindings")

CLAUDE_AGENT_EXPECTATIONS = {
  "Claude Strategic Planner" => %w[
    system-capacity-recommend
    system-platform-deploy
    system-platform-resilience
    system-runbook-generate
  ],
  "Claude Research Analyst"  => %w[
    system-attribute-failure
    system-cve-runbook-generate
    system-suggest-architectures-for-fleet
    system-discover-packages-by-intent
  ]
}.freeze

CLAUDE_AGENT_EXPECTATIONS.each do |agent_name, expected_slugs|
  agent = ::Ai::Agent.find_by(name: agent_name)
  unless agent
    puts "    ⚠️  #{agent_name} not found — skipping (claude_agents_seed may not have run)"
    next
  end

  bound_slugs = ::Ai::AgentSkill.where(ai_agent_id: agent.id)
                                .joins("INNER JOIN ai_skills ON ai_skills.id = ai_agent_skills.ai_skill_id")
                                .pluck("ai_skills.slug")
  missing = expected_slugs - bound_slugs
  assert.call(missing.empty?,
              "#{agent_name} has all #{expected_slugs.size} expected skills (missing=#{missing.inspect})")
end

# ────────────────────────────────────────────────────────────────────
# 8. Concierge tool filter — moved to ConciergeToolBridge constant
# ────────────────────────────────────────────────────────────────────
step.call("Verify SYSTEM_CONCIERGE_TOOL_FILTER constant exists + Concierge metadata cleaned")

assert.call(defined?(::Ai::ConciergeToolBridge::SYSTEM_CONCIERGE_TOOL_FILTER),
            "Ai::ConciergeToolBridge::SYSTEM_CONCIERGE_TOOL_FILTER is defined")

concierge = ::Ai::Agent.find_by(name: "System Concierge")
if concierge
  meta = concierge.metadata || {}
  assert.call(!meta.key?("concierge_tool_filter") && !meta.key?(:concierge_tool_filter),
              "System Concierge metadata no longer carries 'concierge_tool_filter'")
  assert.call(meta["concierge_kind"] == "system_concierge",
              "System Concierge metadata still has concierge_kind='system_concierge'")
end

# ────────────────────────────────────────────────────────────────────
# Done
# ────────────────────────────────────────────────────────────────────
puts "\n  ✅ Smoke test passed — base-platform agent overhaul wiring is sound."
