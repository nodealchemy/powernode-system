# frozen_string_literal: true

# System extension — Powernode Platform category triplet seed.
#
# Creates the "Powernode Platform" NodeModuleCategory triplet (subscription
# + config + instance variants) at position 500 for every account. This is
# the category that holds the platform's own self-deploy modules:
#
#   - powernode-base-ruby
#   - powernode-postgres
#   - powernode-redis
#   - powernode-reverse-proxy            (Traefik + ACME — P2.5 lives here)
#   - powernode-hub-backend
#   - powernode-hub-worker
#   - powernode-hub-frontend
#   - powernode-pg-replica               (cluster_member spawn mode only)
#   - powernode-extension-<slug>         (one per enabled extension)
#
# Plan reference: Decentralized Federation §B, P1.7.
# Plan file: ~/.claude/plans/the-powrnode-platform-consists-peppy-salamander.md
#
# Position 500 places the category between foundational categories
# (system-base ≈ 0-100) and operator workload tiers (typically 600+).
# Modules in this category load AFTER base OS modules in the overlay
# stack but BEFORE customer-specific workload overrides.
#
# Idempotent: re-running checks for existing triplets and skips creation.
#
# Invoke explicitly:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/powernode_platform_categories.rb')"

POWERNODE_PLATFORM_CATEGORY_BASE_NAME = "Powernode Platform"
POWERNODE_PLATFORM_CATEGORY_POSITION  = 500

puts "\n  Seeding Powernode Platform category triplet..."

created = 0
skipped = 0

::Account.find_each do |account|
  existing = ::System::NodeModuleCategory.find_by(
    account: account,
    name: POWERNODE_PLATFORM_CATEGORY_BASE_NAME,
    variety: "subscription"
  )

  if existing
    skipped += 1
    next
  end

  ::System::NodeModuleCategory.create_triplet!(
    account: account,
    base_name: POWERNODE_PLATFORM_CATEGORY_BASE_NAME,
    base_position: POWERNODE_PLATFORM_CATEGORY_POSITION,
    enabled: true,
    public: false
  )
  created += 1
  puts "    ✓ Account #{account.id}: created Powernode Platform triplet at positions " \
       "#{POWERNODE_PLATFORM_CATEGORY_POSITION}/#{POWERNODE_PLATFORM_CATEGORY_POSITION + 1}/" \
       "#{POWERNODE_PLATFORM_CATEGORY_POSITION + 2}"
end

puts "  Powernode Platform categories: #{created} created, #{skipped} already present"
