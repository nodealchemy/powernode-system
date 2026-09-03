# frozen_string_literal: true

require_relative "concerns/agent_setup_helpers"

# System agent hierarchy (HIER-P1) — System Concierge is the root and the
# domain agents are its children: one active Ai::AgentLineage edge each
# (spawn_reason "seed") and one Ai::DelegationPolicy row per agent. The
# attach list is PolicyDeclarations::AGENT_IDENTITIES (through
# HierarchyReconciler::CHILD_IDENTITIES): the seven seeded today (Fleet
# Autonomy, SDWAN Manager, CVE Responder, Disk Image Manager, Runtime Manager,
# GitOps Reconciler, System Topology Designer) plus the four wave-1 managers
# HIER-P2DECL declared (Capacity / Storage / Ingress / Supply Chain), which
# have no seed until wave 2 — an agent that does not exist is reported below
# as skipped, never raised, so this seed keeps passing between the waves and
# attaches them on the first run after their seeds land.
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
