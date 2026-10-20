# frozen_string_literal: true

# The Fleet Operator canonical (skills-first agents, PRE-2): this extension's one
# agent in core's roster registry. Who it is (slug, name, type, tier, domains,
# routing description, assembly prompt, trust and chain posture) is the spec
# lib/powernode_system/engine.rb registers into Ai::Agents::CanonicalRoster; the
# row-writing mechanics are core's (db/seeds/concerns/canonical_roster_seeder.rb),
# shared with core's own three agents so the two cannot drift.
#
# SHADOW MODE, like core's canonicals: the row is written INACTIVE beside the
# legacy fleet agents (Fleet Autonomy and the domain managers), which keep
# running every lane; tier `standard` (mutating runs are raised by the assembler,
# not by this row); trust (monitored) and the "Fleet Operator Actions" chain
# (4h, reject on timeout) are CREATE-ONLY. This seed writes NO intervention-policy
# row and binds no lane: declared rows have one writer
# (System::Governance::PolicyReconciler; the 35-lane cut-over is a later
# increment). Idempotent: a re-seed changes nothing an operator edited.

puts "\n🛰️  Seeding the Fleet Operator canonical (shadow mode: inactive, no policy rows)..."

require Rails.root.join("db", "seeds", "concerns", "canonical_roster_seeder").to_s

CoreSeeds::CanonicalRosterSeeder.seed!(owner: "extensions/system")
