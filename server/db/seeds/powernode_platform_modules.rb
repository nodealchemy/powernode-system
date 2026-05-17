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
#   - powernode-reverse-proxy      Traefik + ACME DNS-01 (P2.5 lives here)
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
# Invoke explicitly:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/powernode_platform_modules.rb')"

POWERNODE_PLATFORM_CATEGORY_NAME = "Powernode Platform"

# P8.2: per-module manifests live on disk at
# extensions/system/modules/<name>/manifest.yaml. The M1 supply chain
# (build-platform-modules.yaml workflow) and this seed read from the
# same files — a single source of truth. Editing a manifest requires
# editing exactly one file.
POWERNODE_PLATFORM_MODULES_DISK_ROOT = ::Rails.root.join(
  "..", "extensions", "system", "modules"
).to_s.freeze

def load_platform_module_manifests_from_disk
  unless ::Dir.exist?(POWERNODE_PLATFORM_MODULES_DISK_ROOT)
    raise "Platform modules disk root missing: #{POWERNODE_PLATFORM_MODULES_DISK_ROOT}. " \
          "Create extensions/system/modules/<name>/manifest.yaml for each platform module."
  end
  manifests = {}
  ::Dir.entries(POWERNODE_PLATFORM_MODULES_DISK_ROOT).sort.each do |entry|
    next if entry.start_with?(".")
    mfpath = ::File.join(POWERNODE_PLATFORM_MODULES_DISK_ROOT, entry, "manifest.yaml")
    next unless ::File.file?(mfpath)
    manifests[entry] = ::File.read(mfpath)
  end
  raise "No platform module manifests found under #{POWERNODE_PLATFORM_MODULES_DISK_ROOT}" if manifests.empty?
  manifests
end

PLATFORM_MODULE_MANIFESTS_TO_SEED = load_platform_module_manifests_from_disk
puts "  Loaded #{PLATFORM_MODULE_MANIFESTS_TO_SEED.size} platform module manifests from #{POWERNODE_PLATFORM_MODULES_DISK_ROOT}"

puts "\n  Seeding Powernode Platform modules (#{PLATFORM_MODULE_MANIFESTS_TO_SEED.size} modules)..."

created = 0
updated = 0
errors  = []

::Account.find_each do |account|
  category = ::System::NodeModuleCategory.find_by(
    account: account,
    name: POWERNODE_PLATFORM_CATEGORY_NAME,
    variety: "subscription"
  )

  unless category
    errors << "Account #{account.id}: Powernode Platform category missing — run powernode_platform_categories.rb first"
    next
  end

  PLATFORM_MODULE_MANIFESTS_TO_SEED.each do |module_name, manifest_yaml|
    mod = ::System::NodeModule.find_or_initialize_by(
      account: account,
      name: module_name
    )
    was_new = mod.new_record?

    mod.variety = "subscription"
    mod.category = category
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
end

puts "  Powernode Platform modules: #{created} created, #{updated} updated"
if errors.any?
  puts "  ⚠ Errors encountered:"
  errors.each { |e| puts "    - #{e}" }
end
