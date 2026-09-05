# frozen_string_literal: true

# System extension — Powernode Platform modules seed.
#
# Creates the 9 platform modules that compose the Powernode platform itself.
# These modules are what make the platform deploy itself onto its own fleet
# (the "Powernode runs Powernode" goal from the Decentralized Federation plan).
#
#   - powernode-base-ruby          Ruby 3.3 + bundler + build deps
#   - powernode-postgres           PostgreSQL 16 primary
#   - powernode-redis              Redis for Sidekiq + ActionCable + cache
#   - reverse-proxy-traefik      Traefik + ACME DNS-01 (P2.5 lives here)
#   - powernode-hub-backend        Rails API + ActionCable
#   - powernode-hub-worker         Sidekiq worker (API-only HTTP to backend)
#   - powernode-hub-frontend       Vite static assets (served by reverse-proxy)
#   - powernode-pg-replica         PG streaming replica (cluster_member only)
#   - powernode-extension-system   System extension Rails engine
#
# Each module's manifest_yaml is the authoritative source; it's parsed by
# System::ManifestImportService into ModuleService rows. The on-node Go
# agent reads the same manifest_yaml at attach time.
#
# Plan reference: Decentralized Federation §B, P1.8.
# Plan file: ~/.claude/plans/the-powrnode-platform-consists-peppy-salamander.md
#
# Depends on:
#   - powernode_platform_categories.rb (P1.7) — must run first
#   - node_module_catalog.rb           — for the ubuntu-24.04-lts NodePlatform
#
# Idempotent: re-running upserts existing modules via find_or_initialize_by;
# ManifestImportService.import! is itself idempotent.
#
# Categorization (campaign 019f6084): each manifest declares which
# System::NodeModuleCategory::PLATFORM_TAXONOMY bucket it belongs in via a
# `category:` field; ManifestImportService::import! resolves + assigns it.
# Before that resolution runs, every module is pre-seeded into the
# "workloads" fallback bucket below — belt-and-suspenders so a future
# platform manifest that omits `category:` still lands somewhere sane
# instead of nil (uncategorized, sorts as if category.position == 0 — below
# EVERY real category, silently at the bottom of the overlay stack).
#
# Two-pass dependency resolution (campaign 019f6084): PLATFORM_MODULE_
# MANIFESTS_TO_SEED.each below imports every manifest in a single
# alphabetical pass. A `requires: capability:<tag>` (or a bare name-based
# `requires:`) only resolves if the PROVIDING module already exists (with
# its `capabilities` populated) at the moment the CONSUMING module is
# imported — e.g. claude-tmux (c...) requires capability:runtime.node,
# provided by runtime-node (r...), which sorts and therefore imports AFTER
# it, so the edge silently defers on pass 1 (inc1's os.userland edges only
# resolved on a single pass because base-os-ubuntu-noble happens to sort
# first alphabetically — every consumer of that capability sorts after its
# provider by coincidence, not by design). Pass 2 re-resolves every
# manifest's dependencies: requires: block after all 20 modules (and their
# capabilities) exist, so forward-reference order no longer matters.
#
# Invoke explicitly:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/powernode_platform_modules.rb')"

# P8.2: per-module manifests live on disk at
# extensions/system/modules/<name>/manifest.yaml. The M1 supply chain
# (build-platform-modules.yaml workflow) and this seed read from the
# same files — a single source of truth. Editing a manifest requires
# editing exactly one file. Discovery lives in
# System::PlatformModuleManifestLoader, which skips untracked dirs
# (F7-03 resurrection-debris guard) when git info is available.
POWERNODE_PLATFORM_MODULES_DISK_ROOT = ::System::PlatformModuleManifestLoader::DEFAULT_ROOT

# DISK-ROOT GUARD — the precondition for listing this file in
# SYSTEM_SEED_FILES at all.
#
# powernode-extension-system's manifest MASKS
# /opt/powernode/extensions/system/modules/*** out of the shipped artifact
# (alongside .git/, docs/, initramfs/, agent/dist/), so on a module-composed
# hub this tree does not exist and load_from_disk RAISES. The orchestrator
# rescues and logs a ❌, which would put a permanent red line in every such
# install's db:seed output for a seed that has nothing to do there.
#
# So: skip, loudly and successfully, when the tree is absent. Where the tree
# IS present — a source checkout, CI, a dev-cell — the seed runs and the
# NodeModule rows land on db:seed instead of only on an explicit rails runner.
#
# This is NOT a silent no-op: an operator invoking the file directly on a
# plane with no modules tree gets the same message and a zero exit rather
# than a backtrace, which is the honest outcome either way. The raise stays
# in load_from_disk for callers that genuinely require the tree.
unless ::Dir.exist?(POWERNODE_PLATFORM_MODULES_DISK_ROOT)
  puts "  ⏭  Skipping platform modules seed: no modules tree at " \
       "#{POWERNODE_PLATFORM_MODULES_DISK_ROOT} (masked out of the deployed " \
       "extension artifact — expected on a module-composed hub)."
  return
end

PLATFORM_MODULE_MANIFESTS_TO_SEED = ::System::PlatformModuleManifestLoader.load_from_disk
puts "  Loaded #{PLATFORM_MODULE_MANIFESTS_TO_SEED.size} platform module manifests from #{POWERNODE_PLATFORM_MODULES_DISK_ROOT}"

puts "\n  Seeding Powernode Platform modules (#{PLATFORM_MODULE_MANIFESTS_TO_SEED.size} modules)..."

created = 0
updated = 0
errors  = []

::Account.find_each do |account|
  fallback_category = ::System::NodeModuleCategory.for_platform_slug!(account: account, slug: "workloads")

  PLATFORM_MODULE_MANIFESTS_TO_SEED.each do |module_name, manifest_yaml|
    mod = ::System::NodeModule.find_or_initialize_by(
      account: account,
      name: module_name
    )
    was_new = mod.new_record?

    mod.variety = "subscription"
    # Fallback only — every shipped manifest declares its own `category:`,
    # which ManifestImportService::import! resolves and overrides below.
    mod.category ||= fallback_category
    mod.enabled = true
    mod.public = false
    mod.priority = 50
    mod.lock_spec = false
    mod.save!

    result = ::System::ManifestImportService.import!(
      node_module: mod,
      yaml: manifest_yaml,
      create_version: false
    )

    if result.ok?
      if was_new
        created += 1
        puts "    ✓ Account #{account.id}: created #{module_name} (#{mod.module_services.size} services)"
      else
        updated += 1
      end
    else
      errors << "Account #{account.id} / #{module_name}: #{result.error}"
    end
  end

  # Pass 2 — see the "Two-pass dependency resolution" header note above.
  PLATFORM_MODULE_MANIFESTS_TO_SEED.each do |module_name, manifest_yaml|
    mod = ::System::NodeModule.find_by(account: account, name: module_name)
    next unless mod # pass 1 failed to create/import it; already in errors

    reresolved = ::System::ManifestImportService.reresolve_dependencies!(
      node_module: mod, yaml: manifest_yaml
    )
    errors << "Account #{account.id} / #{module_name} (pass 2 re-resolve): #{reresolved.error}" unless reresolved.ok?
  end
end

puts "  Powernode Platform modules: #{created} created, #{updated} updated"
if errors.any?
  puts "  ⚠ Errors encountered:"
  errors.each { |e| puts "    - #{e}" }
end
