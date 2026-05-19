# frozen_string_literal: true

# Smoke test for the bare-metal physical-device claim flow.
#
# Exercises the three-step PhysicalEnrollmentService state machine end-to-end:
#   1. record_discovery!  — anonymous device polls /node_api/claim
#   2. confirm_claim!     — operator binds the device to a NodeInstance
#   3. poll_status        — device's next poll returns the bootstrap token
#
# Then validates the bootstrap token returned in step 3 is non-empty and the
# UnclaimedDevice / NodeInstance rows are in the expected post-claim shape.
#
# Invoke:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_bare_metal_claim.rb')"
#
# Reference: audit plan P3.5 (~/.claude/plans/forform-a-deep-examination-fizzy-lobster.md).
# Backlog source: project_smoke_test_state.md ("claim flow scaffolded, no live smoke").

puts "\n  Smoke-test: bare-metal physical-device claim…"

account = ::Account.first or abort("  ❌ No account in DB — seed an Account first")

# Synthetic discovery payload. Unique MAC per run so we never collide with a
# prior smoke's row (UnclaimedDevice upserts on (account_id, discovered_mac)
# scoped to non-expired rows; reusing a MAC would refresh instead of create).
ts       = Time.current.to_i
mac      = "dc:a6:32:%02x:%02x:%02x" % [(ts >> 16) & 0xff, (ts >> 8) & 0xff, ts & 0xff]
dmi_uuid = SecureRandom.uuid
hostname = "smoke-claim-#{ts}"

puts "  Discovery payload: mac=#{mac} dmi_uuid=#{dmi_uuid} hostname=#{hostname}"

# ── Step 1: First /claim poll → row created, status=pending ────────────────

result = ::System::PhysicalEnrollmentService.record_discovery!(
  mac:           mac,
  dmi_uuid:      dmi_uuid,
  hostname:      hostname,
  agent_version: "0.1.0-smoke",
  architecture:  "arm64",
  platform_hint: "rpi4",
  account:       account
)
abort("  ❌ record_discovery returned no unclaimed device") unless result&.unclaimed
abort("  ❌ first discovery should have created a fresh row (got created=#{result.created})") \
  unless result.created
unclaimed = result.unclaimed
puts "  ✓ Discovery recorded: claim_code=#{unclaimed.claim_code} expires_at=#{unclaimed.expires_at.iso8601}"

poll = ::System::PhysicalEnrollmentService.poll_status(unclaimed)
abort("  ❌ expected status=pending, got #{poll.status.inspect}") unless poll.status == "pending"
abort("  ❌ expected claim_code in pending response") unless poll.claim_code == unclaimed.claim_code
puts "  ✓ Poll returns status=pending with claim_code=#{poll.claim_code}"

# ── Step 2: Operator confirms (binds an existing NodeInstance) ─────────────

# Reuse existing template/node if present; otherwise create minimal placeholders.
# These are scoped to a "smoke" namespace so they don't collide with operator
# infrastructure. NodeTemplate requires a NodePlatform — pick one already seeded
# for this account (every platform install ships at least ubuntu-24.04-lts).
node_platform = ::System::NodePlatform.where(account: account).order(:created_at).first \
  or abort("  ❌ No NodePlatform seeded for this account — run rails db:seed first")

template = ::System::NodeTemplate.find_or_create_by!(
  account: account, name: "smoke-bare-metal-claim"
) do |t|
  t.node_platform = node_platform
  t.description   = "Auto-created by smoke_test_bare_metal_claim.rb — safe to delete"
end

node = ::System::Node.find_or_create_by!(
  account: account, name: "smoke-bare-metal-node-#{ts}"
) do |n|
  n.node_template = template
  n.description   = "Auto-created by smoke_test_bare_metal_claim.rb"
end

# variety: "physical" is required for the claim flow — a "cloud" instance
# wouldn't have a discovered MAC/DMI tuple to bind to. network_profile:
# "lightweight" is the default for unmanaged-runtime devices like RPi 4 /
# generic UEFI arm64 hardware.
instance = ::System::NodeInstance.create!(
  account:         account,
  node:            node,
  name:            "smoke-bare-metal-instance-#{ts}",
  variety:         "physical",
  status:          "pending",
  network_profile: "lightweight"
)

puts "  Operator confirms: device #{unclaimed.id} ↔ NodeInstance #{instance.id}"
confirm = ::System::PhysicalEnrollmentService.confirm_claim!(
  unclaimed:     unclaimed,
  node_instance: instance,
  by_user:       nil
)
abort("  ❌ confirm_claim failed: #{confirm.error}") unless confirm.ok?
puts "  ✓ Operator confirmed the device-to-instance binding"

# ── Step 3: Next /claim poll returns the bootstrap token ───────────────────

unclaimed.reload
poll = ::System::PhysicalEnrollmentService.poll_status(unclaimed)
abort("  ❌ expected status=claimed, got #{poll.status.inspect}") unless poll.status == "claimed"
abort("  ❌ expected non-empty bootstrap_token (got #{poll.bootstrap_token.inspect})") \
  unless poll.bootstrap_token.is_a?(String) && poll.bootstrap_token.length >= 32
abort("  ❌ expected instance_uuid=#{instance.id}, got #{poll.instance_uuid.inspect}") \
  unless poll.instance_uuid == instance.id
puts "  ✓ Poll returns status=claimed with bootstrap_token (#{poll.bootstrap_token.length} chars)"

# ── Final assertions on the post-claim state ───────────────────────────────

unclaimed.reload
instance.reload
abort("  ❌ unclaimed.claimed_at not set") unless unclaimed.claimed_at
abort("  ❌ unclaimed.claimed_node_instance_id != instance.id") \
  unless unclaimed.claimed_node_instance_id == instance.id
abort("  ❌ instance.claim_code mismatch") unless instance.claim_code == unclaimed.claim_code
abort("  ❌ instance.discovered_mac mismatch") unless instance.discovered_mac == mac
abort("  ❌ instance.claimed_at not set") unless instance.claimed_at

puts ""
puts "  PASS — bare-metal claim flow exercised end-to-end."
puts "         UnclaimedDevice ##{unclaimed.id} bound to NodeInstance ##{instance.id}."
puts "         Cleanup (optional): NodeInstance.find(#{instance.id.inspect}).destroy ;"
puts "                             Node.find(#{node.id.inspect}).destroy ;"
puts "                             NodeTemplate.find(#{template.id.inspect}).destroy ;"
puts "                             UnclaimedDevice.find(#{unclaimed.id.inspect}).destroy"
