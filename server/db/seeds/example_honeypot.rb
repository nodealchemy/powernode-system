# frozen_string_literal: true

# Companion seed for docs/examples/08-honeypot-canary.md.
#
# Sets up a canary module assignment + simulates an unauthorized access event
# directly via FleetEvent (since the agent-side inotify watcher requires a
# running NodeInstance). Verifies the platform-side response — sensor +
# escalation chain.
#
# Idempotent.
#
# Run via:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/example_honeypot.rb')"

puts "\n  Seeding example_honeypot (Example 08)..."

account = ::Account.first
return puts("  ⚠️  No account — skipping") unless account
user = account.users.find_by(email: "admin@powernode.org") || account.users.first
return puts("  ⚠️  No admin user — skipping") unless user

# ── Need a NodeInstance to attach the canary to ──────────────────────────

instance = ::System::NodeInstance.joins(:node).where(system_nodes: { account_id: account.id }).first
unless instance
  puts "  ⚠️  No NodeInstance found — provision one first via smoke_test_provision.rb or similar"
  return
end
puts "  ✅ Target instance: #{instance.id[0, 8]} (#{instance.node.hostname})"

# ── Ensure honeypot-canary module exists ──────────────────────────────────

category = ::System::NodeModuleCategory.find_or_create_by!(account: account, name: "Security") do |c|
  c.position = 30
end

canary_module = ::System::NodeModule.find_or_initialize_by(account: account, name: "honeypot-canary")
if canary_module.new_record?
  canary_module.assign_attributes(
    category: category,
    variety: "subscription",
    description: "Honeypot canary — file + port watchers that emit signals on unauthorized access"
  )
  canary_module.save!
end
puts "  ✅ Module: honeypot-canary"

# ── Simulate the canary access signal ─────────────────────────────────────

# In production, the agent's inotify watcher posts this via worker_api/events.
# Here we insert directly to verify the sensor + escalation chain.

correlation_id = SecureRandom.uuid

event = ::System::FleetEvent.create!(
  account: account,
  kind: "honeypot.access_attempted",
  severity: "high",
  payload: {
    "node_instance_id" => instance.id,
    "canary_path" => "/etc/cluster-admin-credentials.yaml",
    "accessing_process" => "bash",
    "accessing_user" => "demo-attacker",
    "accessed_at" => Time.current.iso8601,
    "drill" => true                              # explicit drill marker
  },
  correlation_id: correlation_id,
  resource_type: "system.node_instance",
  resource_id: instance.id
)
puts "  ✅ FleetEvent emitted: kind=honeypot.access_attempted, severity=high"

# ── Verify sensor would respond ──────────────────────────────────────────

sensor_class = ::System::Fleet::Sensors::HoneypotAccessSensor rescue nil
unless sensor_class
  puts "  ⚠️  HoneypotAccessSensor class not found — sensor wiring incomplete"
  return
end

sensor = sensor_class.new(account: account)
signals = sensor.tick(account: account) rescue []

if signals.any?
  puts "  ✅ Sensor tick produced #{signals.size} signal(s):"
  signals.each do |s|
    puts "       #{s.kind} (#{s.severity}) — correlation_id=#{s.correlation_id[0, 8]}"
  end
else
  puts "  ℹ️  Sensor ran but produced no signals — may need additional state setup"
end

puts "  ℹ️  Production response would be:"
puts "       1. Sensor emits honeypot.escalation event (high severity)"
puts "       2. Operator notification fires (no auto-action policy)"
puts "       3. Operator investigates: isolate, snapshot, forensic analysis"
puts "       4. Document incident response via create_learning"
puts ""
puts "  ⚠️  Drill correlation_id: #{correlation_id}"
puts "       To clean up: System::FleetEvent.where(correlation_id: '#{correlation_id}').destroy_all"
puts "  Done. See docs/examples/08-honeypot-canary.md."
