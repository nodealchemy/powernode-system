# frozen_string_literal: true

# Companion seed for docs/examples/06-instance-pool-bursty-batch.md (slice 7).
#
# Creates a small InstancePool, demonstrates the reaper + atomic claim path.
# Platform-side only — does not require provider VM creation; pool members
# stay in `warming` status as a demonstration of the data plane.
#
# Idempotent.
#
# Run via:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/example_instance_pool.rb')"

puts "\n  Seeding example_instance_pool (Example 06)..."

account = ::Account.first
return puts("  ⚠️  No account — skipping") unless account
user = account.users.find_by(email: "admin@powernode.org") || account.users.first
return puts("  ⚠️  No admin user — skipping") unless user

# ── Need a Template + provider config for the pool ───────────────────────

template = ::System::NodeTemplate.find_or_initialize_by(account: account, name: "ml-training-demo-template")
if template.new_record?
  template.description = "Demo template for example 06 — ephemeral pool members"
  template.save!
end
puts "  ✅ Template: #{template.name}"

# Pool requires provider_region_id + provider_instance_type_id; use first available.
region = ::System::ProviderRegion.first
instance_type = ::System::ProviderInstanceType.first
unless region && instance_type
  puts "  ⚠️  No ProviderRegion / ProviderInstanceType found — pool needs at least one of each"
  puts "       (these are typically seeded by node_module_catalog.rb or similar)"
  return
end
puts "  ✅ Provider region:        #{region.slug || region.name}"
puts "  ✅ Provider instance type: #{instance_type.slug || instance_type.name}"

# ── Create the pool ───────────────────────────────────────────────────────

pool = ::System::InstancePool.find_or_initialize_by(account: account, name: "ml-training-pool-demo")
if pool.new_record?
  pool.assign_attributes(
    description: "Warm pool for example 06 burst demo",
    template: template,
    provider_region: region,
    provider_instance_type: instance_type,
    target_size: 3,
    min_size: 1,
    max_size: 5,
    warmup_grace_seconds: 600,
    status: "warming"
  )
  pool.save!
end
puts "  ✅ InstancePool: #{pool.name} (target_size=#{pool.target_size})"

# ── Trigger replenishment ─────────────────────────────────────────────────

replenisher = ::System::InstancePoolService.new(account: account)
replenish_result = replenisher.replenish!(pool: pool)

if replenish_result.is_a?(Hash) && replenish_result[:success]
  puts "  ✅ Replenisher kicked: provisioned=#{replenish_result[:provisioned] || 0}"
else
  puts "  ℹ️  Replenisher returned non-success — likely needs the worker job to run"
  puts "       (system_pool_replenish Sidekiq job handles this in production)"
end

# ── Demo claim ────────────────────────────────────────────────────────────

claim_result = replenisher.acquire!(
  pool: pool,
  acquired_by: "demo_seed",
  acquired_for: "example-06-walkthrough"
)

if claim_result.is_a?(Hash) && claim_result[:instance]
  puts "  ✅ Claimed instance: #{claim_result[:instance].id[0, 8]} (claim atomic via SELECT FOR UPDATE SKIP LOCKED)"
  puts "       To return: ::System::InstancePoolService.new(account: account).return!(claim_id: ...)"
else
  puts "  ℹ️  No ready members to claim yet (pool members are warming; needs reaper tick)"
end

puts "  ℹ️  In production, watch pool events:"
puts "       platform.recent_events({ kind_prefix: 'pool', limit: 50 })"
puts "  Done. See docs/examples/06-instance-pool-bursty-batch.md."
