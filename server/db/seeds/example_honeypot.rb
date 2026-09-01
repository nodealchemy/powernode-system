# frozen_string_literal: true

# Companion seed for docs/tutorials/09-honeypot-canary.md.
#
# Sets up a canary module + node assignment, then simulates an unauthorized
# access through the REAL producer (System::Honeypot::CanaryModuleService),
# since the agent-side inotify watcher requires a running NodeInstance.
# Verifies the platform-side response — sensor + escalation chain.
#
# THIS IS A DRILL THAT CAN FAIL. Every step that the chain depends on is
# asserted and `abort`s (SystemExit, status 1) when it does not hold, matching
# the sibling smoke_test_* seeds: these run under `rails runner`, where the
# operator's oracle is the exit status. An earlier revision emitted a
# fabricated event kind, called a sensor method that does not exist behind
# `rescue []`, printed the zero-signal outcome as an informational note, and
# still exited 0 — a drill that could not fail (IMP-b5fabc7a9d7f).
#
# The three PRECONDITION checks below (no account / no user / no NodeInstance)
# stay non-fatal skips: they mean the drill could not be RUN, which is a
# different outcome from the chain being broken, and they match the other
# example_* seeds. Everything from the canary marker onwards is the chain
# itself and aborts.
#
# Idempotent, but NOT read-only: it marks the module, creates a node module
# assignment, and writes FleetEvents. The closing block lists everything to
# clean up. Do not point it at a database whose event log you care about.
#
# Run via:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/example_honeypot.rb')"

puts "\n  Seeding example_honeypot (Tutorial 09)..."

account = ::Account.first
return puts("  ⚠️  No account — skipping") unless account
user = account.users.find_by(email: "admin@powernode.org") || account.users.first
return puts("  ⚠️  No admin user — skipping") unless user

# ── Need a NodeInstance to attach the canary to ──────────────────────────

# Prefer a RUNNING instance: HoneypotAccessSensor binds the quarantine target
# from running instances on nodes hosting the canary, so a stopped one exercises
# only the instance-less fallback arm.
scope = ::System::NodeInstance.where(account_id: account.id)
instance = scope.where(status: "running").first || scope.first
unless instance
  puts "  ⚠️  No NodeInstance found — provision one first via smoke_test_provision.rb or similar"
  return
end
puts "  ✅ Target instance: #{instance.id[0, 8]} (#{instance.node.name})"

# ── Ensure honeypot-canary module exists ──────────────────────────────────

# Existing per-account category names use lowercase ("security", "database",
# etc.); name uniqueness is case-insensitive on (account_id, name), so
# using "Security" would 422 with "Name has already been taken".
category = ::System::NodeModuleCategory.find_or_create_by!(account: account, name: "security") do |c|
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

# ── Mark it a canary and assign it to the target node ─────────────────────

# The producer only emits for modules actually marked as canaries, and the
# sensor can only bind a quarantine target when an ENABLED assignment puts the
# module on a node that hosts running instances. Both are part of the drill's
# setup, not incidental.
unless ::System::Honeypot::CanaryModuleService.mark!(node_module: canary_module)
  abort("  ❌ CanaryModuleService.mark! failed — canary marker not stored")
end
unless ::System::Honeypot::CanaryModuleService.canary?(node_module: canary_module.reload)
  abort("  ❌ Module is not marked as a canary — the producer would no-op")
end
puts "  ✅ Marked honeypot-canary as a canary"

assignment = ::System::NodeModuleAssignment.find_or_create_by!(
  node_id: instance.node_id,
  node_module_id: canary_module.id
) { |a| a.enabled = true }
abort("  ❌ Canary assignment is disabled — sensor cannot resolve a target") unless assignment.enabled?
puts "  ✅ Assignment: #{canary_module.name} → #{instance.node.name}"

# ── Simulate the canary access signal ─────────────────────────────────────

# In production, the agent's inotify watcher posts this via worker_api/events,
# which lands in CanaryModuleService.observe_access!. The drill calls that same
# producer rather than hand-writing a FleetEvent: a hand-written `kind:` is
# free to drift away from the one HoneypotAccessSensor reads, and did.

event = ::System::Honeypot::CanaryModuleService.observe_access!(
  node_module: canary_module,
  source: "drill",
  context: {
    "node_instance_id" => instance.id,
    "canary_path" => "/etc/cluster-admin-credentials.yaml",
    "accessing_process" => "bash",
    "accessing_user" => "drill-attacker",
    "accessed_at" => Time.current.iso8601,
    "drill" => true                              # explicit drill marker
  }
)

# EventBroadcaster.emit! swallows persistence failures and returns nil, so a
# nil here means the event never reached the log the sensor reads.
abort("  ❌ observe_access! produced no FleetEvent — the producer is broken") unless event
puts "  ✅ FleetEvent emitted: kind=#{event.kind}, severity=#{event.severity}, id=#{event.id[0, 8]}"

# ── Verify the sensor actually observed it ────────────────────────────────

# No `rescue` on either line. A missing sensor class or a raising sense are
# broken-chain outcomes; funnelling them into an empty signal list is what let
# the previous revision report success on a chain it never exercised.
unless defined?(::System::Fleet::Sensors::HoneypotAccessSensor)
  abort("  ❌ HoneypotAccessSensor class not found — sensor wiring incomplete")
end

# A sensor that EXISTS but is not in the tick registry escalates nothing in
# production. The drill has to instantiate the class directly (it runs outside
# a tick), which verifies the sensor and NOT its wiring — precisely the
# component-vs-wiring confusion this drill was fixed for. So assert membership
# rather than infer it.
sensor_class = ::System::Fleet::Sensors::HoneypotAccessSensor
unless ::System::Fleet::FleetAutonomyService::SENSORS.include?(sensor_class)
  abort("  ❌ #{sensor_class} is not in FleetAutonomyService::SENSORS — it never runs in a tick")
end

sensor  = sensor_class.new(account: account)
signals = sensor.sense

# THE load-bearing assertion. Not "some signal appeared" and not "the kind
# literal still reads as it did" — the signal the sensor raised must carry
# THIS drill's event id. That is the only check that fails when the producer
# and the sensor stop agreeing on the event kind, and it keeps failing under a
# rename of that kind.
drill_signals = signals.select { |s| s.payload["event_id"] == event.id }
if drill_signals.empty?
  abort(<<~FAIL)
      ❌ ESCALATION CHAIN BROKEN — the sensor did not observe the drill event.
         Emitted: kind=#{event.kind} id=#{event.id}
         Sensor raised #{signals.size} signal(s), none referencing that event.
         HoneypotAccessSensor reads FleetEvents by kind within a #{::System::Fleet::Sensors::HoneypotAccessSensor::LOOKBACK.inspect}
         lookback; check that the kind it queries is the kind
         CanaryModuleService emits.
  FAIL
end

# Severity is the sensor's stated contract: a canary access is by definition an
# indicator of compromise, and the operator queue's ordering depends on it.
non_critical = drill_signals.reject { |s| s.severity == :critical }
abort("  ❌ Escalation raised at #{non_critical.map(&:severity).uniq.inspect}, expected :critical") if non_critical.any?

puts "  ✅ Sensor observed the drill event and escalated #{drill_signals.size} signal(s):"
drill_signals.each do |s|
  target = s.payload["instance_id"] ? " instance=#{s.payload['instance_id'][0, 8]}" : " (no hosting instance)"
  puts "       #{s.kind} (#{s.severity})#{target} fingerprint=#{s.fingerprint}"
end

if drill_signals.none? { |s| s.payload["instance_id"] }
  # Not fatal: the chain works, but the quarantine arm had no target, so the
  # drill exercised the fallback rather than the production shape. Say so
  # instead of letting the success line imply otherwise.
  puts "  ⚠️  No RUNNING instance on #{instance.node.name} — escalated without a quarantine target"
end

# ── Verify the escalation has somewhere to GO ─────────────────────────────

# A signal the DecisionEngine cannot route is classified "skipped" and dies
# there, and an action category no policy declares resolves to
# gate="unknown_policy" => :blocked. Both are silent. The narration below is
# READ from those two tables rather than restated, so it cannot describe a
# response the platform would not actually give.
signal_kind = drill_signals.first.kind
binding = ::System::Fleet::DecisionEngine::SIGNAL_BINDINGS[signal_kind]
action_category = binding && binding[:action_category]
if action_category.blank?
  abort("  ❌ #{signal_kind} is bound to no action category in DecisionEngine::SIGNAL_BINDINGS — the escalation would be classified 'skipped'")
end

policy = ::System::Governance::PolicyDeclarations::FLEET_AUTONOMY_POLICIES[action_category]
if policy.blank?
  abort("  ❌ #{action_category} is declared by no Fleet Autonomy policy — the gate would resolve 'unknown_policy' and block")
end

puts "  ℹ️  Production response from here:"
puts "       1. DecisionEngine routes #{signal_kind} → action_category #{action_category}"
puts "       2. That category's declared policy is #{policy.inspect}"
if policy == "require_approval"
  puts "          → an ApprovalRequest is minted; nothing is terminated without an operator"
end
puts "       3. On approval, the bound instance is quarantined (InstanceControlService terminate)"
puts "       4. Operator investigates: snapshot, forensic analysis"
puts "       5. Document incident response via create_learning"
puts ""
puts "  ⚠️  This drill WROTE to the database. It leaves behind:"
puts "       - FleetEvent #{event.id} (the drill's own event)"
puts "       - on a FIRST run, a second system.honeypot_triggered FleetEvent: creating the"
puts "         assignment fires NodeModuleAssignment#observe_canary_access (after_commit, on create)"
puts "       - the honeypot-canary NodeModule, its canary marker, and its assignment to #{instance.node.name}"
puts "       To clean up:"
puts "         System::FleetEvent.where(account_id: '#{account.id}', kind: '#{event.kind}').destroy_all"
puts "         System::NodeModuleAssignment.where(node_module_id: '#{canary_module.id}').destroy_all"
puts "  Done. See docs/tutorials/09-honeypot-canary.md."
