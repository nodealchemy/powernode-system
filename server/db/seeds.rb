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

ext_seeds = File.expand_path("seeds", __dir__)

# Files that MUST run on every db:seed to keep the extension consistent.
# Smoke tests (smoke_test_*), examples (example_*), and one-off module
# bootstrappers (k3s_modules, sdwan_overlay_module, docker_runtime_module,
# public_package_repositories_seed) are deliberately excluded — they're
# either destructive, expensive, or operator-only.
SYSTEM_SEED_FILES = %w[
  system_storage_permissions.rb
  system_acme_permissions.rb
  system_platform_permissions.rb
  fleet_autonomy_agent.rb
  system_concierge_agent.rb
  system_runtime_manager_agent.rb
  system_cve_responder_agent.rb
  system_disk_image_manager_agent.rb
  system_sdwan_manager_agent.rb
  system_topology_designer_agent.rb
  system_fleet_kg_schema.rb
  system_kg_entities_seed.rb
  system_instance_pool_policies.rb
  system_manual_operation_policies.rb
  system_provisioning_intervention_policies.rb
  system_provisioning_mission_template.rb
  system_skills_seed.rb
  system_provisioning_skills_seed.rb
  system_kb_seed.rb
  node_module_catalog.rb
  role_modules_seed.rb
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
