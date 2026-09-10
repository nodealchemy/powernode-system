# frozen_string_literal: true

require_relative "concerns/agent_setup_helpers"

# System agent hierarchy (HIER-P1) — System Concierge is the root and the
# domain agents are its children: one active Ai::AgentLineage edge each
# (spawn_reason "seed") and one Ai::DelegationPolicy row per agent. The
# attach list is PolicyDeclarations::AGENT_IDENTITIES (through
# HierarchyReconciler::CHILD_IDENTITIES): all eleven domain agents — Fleet
# Autonomy, SDWAN Manager, CVE Responder, Disk Image Manager, Runtime Manager,
# GitOps Reconciler, System Topology Designer, and the four operations
# managers HIER-P2DECL declared in wave 1 and HIER-P2B/P2C/P2D/P2E seeded in
# wave 2 (Capacity / Storage / Ingress / Supply Chain). An agent that does not
# exist is reported below as skipped, never raised (the P1 drift ruling), so a
# future identity declared ahead of its seed keeps this seed passing and is
# attached on the first run after that seed lands.
#
# The declarations and the writes live in System::Governance::HierarchyReconciler
# (reconcile! here; `drift` is the read-only report the governance rake can
# print). Runs AFTER every agent seed and after system_skill_bindings_seed.rb
# in SYSTEM_SEED_FILES. Idempotent: a re-run changes nothing.
#
# The lineage table needs an owning account (a global agent has none): the
# same admin account the agent seeds key their per-account policy rows on.

puts "\n  Seeding system agent hierarchy (domain agents under System Concierge)..."

hierarchy_account = System::Seeds::AgentSetupHelpers.admin_account
raise "system_agent_hierarchy: no Account exists — seed accounts first" unless hierarchy_account

hierarchy_result = System::Governance::HierarchyReconciler.new(account: hierarchy_account).reconcile!

puts "  ✅ #{hierarchy_result.attached} domain agent(s) attached under System Concierge, " \
     "#{hierarchy_result.policies_written} delegation policy write(s)"
puts "  ⚠️  Skipped (agent not seeded — drift until seeded): #{hierarchy_result.skipped.join(', ')}" if hierarchy_result.skipped.any?

# HIER-P2B-ENG — the Engineering hierarchy's root joins the same forest. The
# Platform Architect is a CORE root (db/seeds/ai_agent_hierarchy_seed.rb hangs
# the Engineering agents under it and, core purity forbidding a reach for a
# system agent, leaves it parentless), and its edge under System Concierge used
# to be attached by an inline block RIGHT HERE, because the reconciler excluded
# the core canonicals entirely.
#
# It no longer is (IMP-01a06aee): the reconcile! above walks
# HierarchyReconciler#edge_only_subjects, which covers the core root and every
# CORE_CANONICAL_KEYS canonical — edge only, never the delegation policy core
# owns. That matters beyond tidiness: `db:seed` is FIRST-BOOT ONLY, so this
# block could never reach an install that gained the Platform Architect later,
# and `drift` could not report the edge missing either. One writer, and one that
# runs again.
