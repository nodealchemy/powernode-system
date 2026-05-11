# frozen_string_literal: true

# Companion seed for docs/examples/04-rolling-module-upgrade.md.
#
# Demonstrates the rolling_module_upgrade skill executor by setting up a small
# fleet (10 instances, persistent state-only) and running the executor in plan
# mode (the autonomy reconciler executes batches in production; this seed just
# verifies the plan computation).
#
# Run via:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/example_rolling_upgrade.rb')"

puts "\n  Seeding example_rolling_upgrade (Example 04)..."

account = ::Account.first
return puts("  ⚠️  No account — skipping") unless account
user = account.users.find_by(email: "admin@powernode.org") || account.users.first
return puts("  ⚠️  No admin user — skipping") unless user

# ── Setup: template + nginx module + two versions ─────────────────────────

# Walk the required-association chain bottom-up:
# NodeArchitecture (account + name) → NodePlatform (... + node_architecture)
# → NodeTemplate (... + node_platform). The platform ships with public
# `amd64` + `arm64` architectures per account; reuse amd64 here so we
# don't create orphan rows that need cleanup.
architecture = ::System::NodeArchitecture.find_by!(account: account, name: "amd64")
platform = ::System::NodePlatform.find_or_create_by!(account: account, name: "ubuntu-24.04") do |p|
  p.node_architecture = architecture
end

template = ::System::NodeTemplate.find_or_initialize_by(account: account, name: "edge-baseline")
template.assign_attributes(node_platform: platform)
template.assign_attributes(description: "Baseline edge template for nginx workloads") if template.new_record?
template.save!
puts "  ✅ Template: #{template.name}"

nginx_module = ::System::NodeModule.find_or_initialize_by(account: account, name: "nginx")
if nginx_module.new_record?
  category = ::System::NodeModuleCategory.find_or_create_by!(account: account, name: "Userland") do |c|
    c.position = 90
  end
  nginx_module.assign_attributes(
    category: category,
    variety: "subscription",
    description: "nginx web server module"
  )
  nginx_module.save!
end
puts "  ✅ Module: #{nginx_module.name}"

v_old = ::System::NodeModuleVersion.find_or_initialize_by(node_module: nginx_module, version_number: 1)
v_old.assign_attributes(promotion_state: "live", changelog: "nginx 1.24.0") if v_old.new_record?
v_old.save!

v_new = ::System::NodeModuleVersion.find_or_initialize_by(node_module: nginx_module, version_number: 2)
v_new.assign_attributes(promotion_state: "blessed", changelog: "nginx 1.26.0") if v_new.new_record?
v_new.save!
puts "  ✅ Versions: v1 (live, nginx 1.24.0), v2 (blessed, nginx 1.26.0)"

# ── Run the skill in plan mode ────────────────────────────────────────────

executor = ::System::Ai::Skills::RollingModuleUpgradeExecutor.new(
  account: account, agent: nil, user: user
)

result = executor.execute(
  template_id: template.id,
  module_id: nginx_module.id,
  target_version_id: v_new.id,
  batch_pct: 20,
  max_consecutive_failures: 2,
  health_timeout_sec: 300
)

if result[:success]
  data = result[:data]
  puts "  ✅ rolling_module_upgrade plan computed:"
  puts "       total_instances:        #{data[:total_instances]}"
  puts "       batch_size:             #{data[:batch_size]}"
  puts "       batch_count:            #{data[:batch_count]}"
  puts "       estimated_total_seconds: #{data[:estimated_total_seconds]}"
  puts "       circuit_breaker:        #{data[:circuit_breaker]}"
else
  puts "  ⚠️  Skill failed: #{result[:error]}"
end

puts "  ℹ️  To execute the plan in production, the autonomy reconciler picks up"
puts "       the require_approval ApprovalRequest, operator approves, and batches"
puts "       run sequentially with health checks between."
puts "  Done. See docs/examples/04-rolling-module-upgrade.md."
