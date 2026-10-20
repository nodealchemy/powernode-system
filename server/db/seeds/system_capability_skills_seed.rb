# frozen_string_literal: true

# System extension CAPABILITY skills (skills-first agents, PRE-1): the fleet,
# infrastructure, network, service-exposure and project-delivery capabilities
# whose verbs this extension owns. Data lives in db/seeds/capability_skills/*.yml,
# authored to core's Ai::Skills::Contract; the batch passes core's
# Ai::Skills::SeedGate for this owner (contract, one owner per capability, slug
# collisions, registered verbs, relations to core or this extension only, no
# other extension's verbs, duplicate/overlap bands) before any row is written.
# GLOBAL rows; a re-run never reactivates, re-enables or overwrites an
# operator-modified row. Seeded only when this extension is enabled — the
# orchestrator runs only for loaded extensions.
#
# Runs after core's capability seed (core seeds load before extension seeds),
# because some skills relate to core skills (refines/composes). If those core
# rows are missing the gate rejects the batch; the failure is recorded with
# core's Ai::Skills::CapabilitySeeder.record_failure! BEFORE the orchestrator's
# rescue sees it, so db:seed still ends with the marked error banner.
#
# Legacy system-* skill rows are left untouched; they are retired separately.

puts "\n  Seeding System extension capability skills..."

begin
  entries = Ai::Skills::CapabilitySeeder.load_entries(File.expand_path("capability_skills", __dir__))
  result = Ai::Skills::CapabilitySeeder.new(
    owner_repo: "extensions/system",
    embedder: ENV.fetch("POWERNODE_SKILL_GATE_EMBEDDER", "auto")
  ).seed!(entries)

  Rails.logger.info "[system extension seeds] capability skills: #{result.summary}"
  puts "  ✅ System capability skills: #{result.summary}"
  result.warnings.each do |warning|
    Rails.logger.warn "[system extension seeds] capability skill warning: #{warning}"
    puts "  ⚠️  #{warning}"
  end
  if result.graph_failures.any?
    puts "  ⚠️  Knowledge-graph sync failures: #{result.graph_failures.size}"
    result.graph_failures.first(10).each { |failure| puts "     - #{failure}" }
  end
rescue StandardError => e
  Ai::Skills::CapabilitySeeder.record_failure!("extensions/system", e)
  puts "  ❌ SYSTEM CAPABILITY SKILL SEED FAILED: #{e.class}: #{e.message.lines.first(12).join}"
  raise
end
