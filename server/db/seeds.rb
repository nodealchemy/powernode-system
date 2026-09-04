# frozen_string_literal: true

# System extension's seed orchestrator. Invoked by the parent platform's
# db/seeds.rb extension-seeds loop (server/db/seeds.rb ~line 989) — when
# this file is present, the parent prefers it over globbing db/seeds/*.rb.
#
# Why explicit listing matters: the seeds/ directory ALSO contains
# `smoke_test_*.rb` (live integration test scripts run manually) and
# `example_*.rb` (operator playgrounds). Globbing those breaks `db:seed`
# (the smoke tests create resources mid-run, FK-violate on teardown,
# crash the whole seed pipeline). This file enforces "only the seeds
# that are safe to run on every `rails db:seed` go here."
#
# Manual invocation paths still work for the excluded files:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_<x>.rb')"
#
# Order matters — skill catalogs first, then agents that bind skills,
# then the manual-operations policy seed and the graph/catalog seeds.
#
# NOTE: extension permissions + role grants are NO LONGER seeded imperatively.
# They are declared in lib/powernode_system/engine.rb via the Permissions
# catalog DSL (register_catalog), which registers them at boot and survives
# Role#sync_permissions!'s destructive replace. The former
# system_{storage,acme,platform,cve}_permissions.rb seed files were retired.

ext_seeds = File.expand_path("seeds", __dir__)

# Files that MUST run on every db:seed to keep the extension consistent.
# Smoke tests (smoke_test_*), examples (example_*), and one-off module
# bootstrappers (k3s_modules, sdwan_overlay_module, docker_runtime_module,
# public_package_repositories_seed) are deliberately excluded — they're
# either destructive, expensive, or operator-only.
# `system_agent_hierarchy.rb` runs AFTER every agent seed and after
# `system_skill_bindings_seed.rb`: it attaches every declared domain agent
# (PolicyDeclarations::AGENT_IDENTITIES — all eleven seeded above; HIER-P2DECL
# declared the four operations managers in wave 1 and HIER-P2B/P2C/P2D/P2E
# seeded them in wave 2, so an "(agent absent)" skip line here now means a seed
# above failed, not a pending wave) under System Concierge and derives each
# delegation policy from POLICY_SETS and the SkillBindings registry (HIER-P1),
# so every agent it attaches must already exist. `system_operations_team_seed.rb`
# (HIER-P4) runs right after it: the "System Operations" canonical
# Ai::TeamTemplate is materialised for the admin account on top of those
# edges and delegation rows, so it must see them.
#
# POLICY-WRITE CONVENTION (proposal §5 ruling 7; HIER-P2SWEEP, then
# IMP-10e4f6c3bcd2 / offer 01a0696f):
# System::Governance::PolicyReconciler is the SINGLE WRITER of declared
# intervention-policy rows (POLICY_SETS × AGENT_IDENTITIES plus the
# manual-operations set) — on every boot, the FIRST one included
# (rails-start.sh runs governance-reconcile.rb after db:seed and after every
# later db:migrate), and via `rails system:governance:reconcile`. An agent
# seed writes identity, prompt, approval chain, trust, tool_access and skills
# ONLY; every agent seed below now has the Supply Chain Manager's shape and
# writes NO policy row. The four first-boot policy seeds whose whole body was
# an upsert (system_{instance_pool,instance_cordon,volume_snapshot}_policies,
# system_provisioning_intervention_policies) are DELETED: their sets are
# POLICY_SETS entries the reconciler writes at the declared shape. Do not add
# a seed that writes a declared row — spec/db/seeds/policy_single_writer_spec
# runs every agent seed against an empty database and asserts zero rows, and
# lints the list. `system_governance_policy_reconcile.rb` runs LAST and is how
# the rows reach a `rails db:seed` install: retiring the fourteen upserts left
# the reconciler running only from rails-start.sh (hub images) and the manual
# `rails system:governance:reconcile`, so every other documented install path
# would have come up with NO declared row and gated everything through the
# require_approval default. That file performs no write of its own — it calls
# the single writer, absence-only and idempotent, and (IMP-99988ef54942) core's
# own absence-only engineering-floor seam as a BACKSTOP: not a ruling-7 second
# writer, because those rows are CORE rows with one CORE seam, and core's
# engineering seed lands them first on a baseline `db:seed` — so that
# step normally writes zero. The ONE remaining writer
# besides the reconciler is
# system_manual_operation_policies.rb (outside that task's file list — it still
# upserts the manual-operations set and destroys unlisted system.task.* rows;
# named in that spec as the exception until it is retired the same way).
# `system_skill_graph_sync.rb` runs LAST, after every catalog seed: the catalog
# skills are GLOBAL rows since HIER-P2G and a global row never fires the
# per-account knowledge-graph sync hook, so without it every system skill is
# invisible to `platform.discover_skills` and the ConciergeRouter (both read
# skill NODES, not the ai_skills table).
# `system_autonomy_orphan_cleanup.rb` is second-to-last: a garbage-collection pass wants
# to see every row the seeds above wrote. It is order-independent all the same
# (its predicate is the boot category registry, not any seed's declarations) —
# IMP-0a3ff97f6fbb.
#
# Keep prose OUT of the %w[] literal below: it does not honour `#`, so a comment
# line becomes one array element per word.
SYSTEM_SEED_FILES = %w[
  fleet_autonomy_agent.rb
  system_concierge_agent.rb
  system_runtime_manager_agent.rb
  system_cve_responder_agent.rb
  system_disk_image_manager_agent.rb
  system_sdwan_manager_agent.rb
  system_topology_designer_agent.rb
  system_gitops_reconciler_agent.rb
  system_capacity_manager_agent.rb
  system_storage_manager_agent.rb
  system_ingress_manager_agent.rb
  system_supply_chain_manager_agent.rb
  system_fleet_kg_schema.rb
  system_kg_entities_seed.rb
  system_manual_operation_policies.rb
  system_provisioning_mission_template.rb
  system_agent_fleet_mission_template.rb
  system_skills_seed.rb
  system_provisioning_skills_seed.rb
  system_dr_skills_seed.rb
  system_skill_bindings_seed.rb
  system_kb_seed.rb
  node_module_catalog.rb
  role_modules_seed.rb
  system_agent_hierarchy.rb
  system_operations_team_seed.rb
  system_autonomy_orphan_cleanup.rb
  system_skill_graph_sync.rb
  system_governance_policy_reconcile.rb
].freeze

SYSTEM_SEED_FILES.each do |seed_file|
  path = File.join(ext_seeds, seed_file)
  next unless File.exist?(path)

  begin
    load path
  rescue StandardError => e
    Rails.logger.error("[system extension seeds] #{seed_file} failed: #{e.class}: #{e.message}")
    puts "  ❌ #{seed_file} failed: #{e.message}"
    # Continue — one failed seed shouldn't poison the others
  end
end
