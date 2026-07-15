# frozen_string_literal: true

# System extension — Powernode Platform category taxonomy seed.
#
# Creates one NodeModuleCategory triplet (subscription + config + instance
# variants) per System::NodeModuleCategory::PLATFORM_TAXONOMY entry, for
# every account. Ascending base_position is the overlay-stack order
# (bottom-to-top; see NodeModule#effective_priority — higher category
# position wins the union):
#
#   System Base (120) < Base OS (150) < Language Runtime (250) <
#   Data Plane (300) < Storage & Guest (320) < Networking / Proxy (350) <
#   Observability (400) < Build & Dev (450) < Platform Apps (550) <
#   Workloads (560)
#
# Each of the 20 on-disk manifests (extensions/system/modules/<name>/
# manifest.yaml) declares which bucket it belongs in via a `category:`
# slug; powernode_platform_modules.rb's ManifestImportService::import! call
# resolves that slug against this same taxonomy (self-healing — see
# NodeModuleCategory.for_platform_slug!). This seed is the PRIMARY creator
# of the category rows; the manifest field is the preferred per-module
# assignment mechanism.
#
# Campaign 019f6084 — replaces the single "Powernode Platform" position-500
# catch-all that dumped all 20 platform modules into one category (every
# module's effective_priority tied, so the overlay stack's layer order was
# tie-broken by name/UUID — nondeterministic from the operator's POV). The
# retirement step below destroys that legacy triplet: destroy (never
# delete-if-referenced) is safe here because it only NULLIFIES
# (dependent: :nullify) any NodeModule still pointing at it, and the very
# next seed step (powernode_platform_modules.rb, which MUST run
# immediately after this one) reassigns every platform module to its new
# taxonomy bucket via the manifest `category:` field. Any operator-owned
# module a human had manually filed under the old category becomes
# uncategorized rather than orphaned — a status quo the operator can fix
# from the UI, not a broken FK.
#
# Idempotent: re-running checks for existing rows (by base_name) and skips
# creation; the legacy-category retirement is a no-op once it's gone.
#
# Invoke explicitly:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/powernode_platform_categories.rb')"

LEGACY_POWERNODE_PLATFORM_CATEGORY_BASE_NAME = "Powernode Platform"

puts "\n  Seeding Powernode Platform category taxonomy (#{::System::NodeModuleCategory::PLATFORM_TAXONOMY.size} categories)..."

retired = 0
created = 0
skipped = 0

::Account.find_each do |account|
  legacy = ::System::NodeModuleCategory.find_by(
    account: account,
    name: LEGACY_POWERNODE_PLATFORM_CATEGORY_BASE_NAME,
    variety: "subscription"
  )
  if legacy
    [ legacy, legacy.config_category, legacy.instance_category ].compact.each(&:destroy)
    retired += 1
    puts "    ✓ Account #{account.id}: retired legacy '#{LEGACY_POWERNODE_PLATFORM_CATEGORY_BASE_NAME}' catch-all triplet"
  end

  ::System::NodeModuleCategory::PLATFORM_TAXONOMY.each do |slug, spec|
    existing = ::System::NodeModuleCategory.find_by(
      account: account, name: spec[:base_name], variety: "subscription"
    )
    if existing
      skipped += 1
      next
    end

    ::System::NodeModuleCategory.create_triplet!(
      account: account,
      base_name: spec[:base_name],
      base_position: spec[:base_position],
      enabled: true,
      public: false
    )
    created += 1
    puts "    ✓ Account #{account.id}: created '#{spec[:base_name]}' (#{slug}) triplet at positions " \
         "#{spec[:base_position]}/#{spec[:base_position] + 1}/#{spec[:base_position] + 2}"
  end
end

puts "  Powernode Platform categories: #{created} created, #{skipped} already present, #{retired} legacy triplets retired"
