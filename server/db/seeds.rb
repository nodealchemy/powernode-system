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
# then policy/permission seeds.
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
# so every agent it attaches must already exist.
#
# POLICY-WRITE CONVENTION (HIER-P2SWEEP, driver ruling 2026-09-03):
# System::Governance::PolicyReconciler is the SINGLE WRITER of declared
# intervention-policy rows (POLICY_SETS × AGENT_IDENTITIES, every boot). An
# agent seed writes identity, prompt, approval chain, trust, tool_access and
# skills ONLY — the Supply Chain Manager seed is the reference shape (the only
# agent seed that writes no row). Every other agent seed still upserts its
# declared set at first boot (fleet_autonomy_agent and the system_{runtime_
# manager,cve_responder,disk_image_manager,sdwan_manager,topology_designer,
# gitops_reconciler,capacity_manager,storage_manager,ingress_manager}_agent
# seeds, through AgentSetupHelpers.upsert_policies!), as do the four operator-
# set policy seeds (system_{instance_pool,instance_cordon,volume_snapshot}_
# policies, system_provisioning_intervention_policies). They are grandfathered
# until the reconciler runs BEFORE them at first boot — a live install depends
# on their idempotent upserts today; improvement 01a0696f-823f-7415-acc8-
# a898facabff5 files the rewrite. Do not add a new one.
# `system_autonomy_orphan_cleanup.rb` is last: a garbage-collection pass wants
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
  system_instance_pool_policies.rb
  system_volume_snapshot_policies.rb
  system_instance_cordon_policies.rb
  system_manual_operation_policies.rb
  system_provisioning_intervention_policies.rb
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
  system_autonomy_orphan_cleanup.rb
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
