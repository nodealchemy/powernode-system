# frozen_string_literal: true

# System extension — Smoke-test for Phase O1 (HostBridge + BridgeApplier).
#
# DB-level integration test: allocates a HostBridge for a test host,
# verifies the topology compiler emits it in the per-host payload, and
# verifies the resolver returns the same name. Companion to the agent's
# Go-level LinuxBridgeApplier tests; together they cover the full
# server -> wire -> agent -> kernel path.
#
# Asserts the contract the agent's BridgeApplier consumes:
#   1. HostBridgeAllocator assigns short_id 1 starting (per-host monotonic)
#   2. bridge_name follows `pwnbr-<short_id>` format and fits IFNAMSIZ
#   3. Re-allocation is idempotent (same row + same short_id)
#   4. TopologyCompiler.host_bridges_for(host) emits the bridge with
#      every field the agent's DesiredBridge struct expects
#   5. HostBridgeResolver.bridge_name_for(host) returns the same name
#   6. Marking removed excludes the bridge from compilable scope
#   7. State transitions follow AASM (pending -> active -> draining -> removed)
#
# Invoke:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_host_bridge.rb')"

puts "\n  Smoke-test: Phase O1 — HostBridge + BridgeApplier"
puts "  " + ("=" * 60)

# ── Setup fixtures ────────────────────────────────────────────────────

account  = Account.first or abort("  ❌ No account in DB")
template = System::NodeTemplate.find_by(account: account, name: "base") ||
           System::NodeTemplate.where(account: account).first ||
           abort("  ❌ No node template")
provider = System::Provider.find_by(account: account, provider_type: "local_qemu") or
           abort("  ❌ No local_qemu provider")
region   = provider.provider_regions.first or abort("  ❌ No provider region")
itype    = provider.provider_instance_types.first or abort("  ❌ No instance type")

node = System::Node.find_or_create_by!(account: account, name: "smoke-bridge-host") do |n|
  n.node_template = template
end
instance = System::NodeInstance.find_or_initialize_by(node: node, name: "smoke-bridge-host-instance")
instance.assign_attributes(
  variety: "cloud", provider_region: region, provider_instance_type: itype, status: "running"
)
instance.save!

# Wipe prior smoke fixtures so allocator starts fresh.
::Sdwan::HostBridge.where(node_instance_id: instance.id).destroy_all

puts "  Account:  #{account.id[0..7]}…"
puts "  Host:     #{instance.id[0..7]}…  (#{instance.name})"
puts ""

# ── Test 1: Allocator assigns short_id 1 + name pwnbr-1 ───────────────

hb = ::Sdwan::HostBridgeAllocator.allocate!(host: instance)
abort("  ❌ Test 1 FAILED — allocator returned nil") if hb.nil?
abort("  ❌ Test 1 FAILED — short_id wrong (#{hb.short_id} != 1)") unless hb.short_id == 1
abort("  ❌ Test 1 FAILED — bridge_name wrong (#{hb.bridge_name})") unless hb.bridge_name == "pwnbr-1"
abort("  ❌ Test 1 FAILED — kind wrong (#{hb.kind})") unless hb.kind == "linux"
puts "  ✓ Test 1: HostBridgeAllocator assigned short_id=1, bridge_name=pwnbr-1, kind=linux"

# ── Test 2: Bridge name fits IFNAMSIZ ─────────────────────────────────

abort("  ❌ Test 2 FAILED — name exceeds IFNAMSIZ (#{hb.bridge_name.length} > 15)") if hb.bridge_name.length > 15
puts "  ✓ Test 2: bridge_name length #{hb.bridge_name.length} fits IFNAMSIZ (<=15)"

# ── Test 3: Re-allocation is idempotent ───────────────────────────────

hb2 = ::Sdwan::HostBridgeAllocator.allocate!(host: instance)
abort("  ❌ Test 3 FAILED — re-allocation returned new row id") unless hb2.id == hb.id
abort("  ❌ Test 3 FAILED — re-allocation changed short_id") unless hb2.short_id == hb.short_id
puts "  ✓ Test 3: re-allocation is idempotent (same row id + short_id)"

# ── Test 4: TopologyCompiler emits the bridge in host_bridges_for ─────

# Mark active so the compilable scope picks it up.
hb.mark_active!

bridges = ::Sdwan::TopologyCompiler.host_bridges_for(instance)
abort("  ❌ Test 4 FAILED — host_bridges_for returned empty") if bridges.empty?
entry = bridges.first
%i[host_bridge_id short_id name kind state].each do |k|
  abort("  ❌ Test 4 FAILED — payload entry missing :#{k}") if entry[k].nil?
end
abort("  ❌ Test 4 FAILED — payload :name doesn't match (#{entry[:name]})") unless entry[:name] == "pwnbr-1"
abort("  ❌ Test 4 FAILED — payload :state doesn't match (#{entry[:state]})") unless entry[:state] == "active"
puts "  ✓ Test 4: TopologyCompiler.host_bridges_for emits #{entry[:name]} (#{entry.keys.length} fields)"

# ── Test 5: HostBridgeResolver returns same name ──────────────────────

resolved = ::Sdwan::HostBridgeResolver.bridge_name_for(instance)
abort("  ❌ Test 5 FAILED — resolver returned #{resolved.inspect}, expected pwnbr-1") unless resolved == "pwnbr-1"
puts "  ✓ Test 5: HostBridgeResolver.bridge_name_for returns the allocator's name"

# ── Test 6: Allocate second bridge — short_id increments ──────────────

# Force a second allocation by passing a different kind (multi-kind support).
hb3 = ::Sdwan::HostBridgeAllocator.allocate!(host: instance, kind: "ovs")
abort("  ❌ Test 6 FAILED — second allocation returned same row") if hb3.id == hb.id
abort("  ❌ Test 6 FAILED — short_id didn't increment (#{hb3.short_id})") unless hb3.short_id == 2
abort("  ❌ Test 6 FAILED — bridge_name wrong (#{hb3.bridge_name})") unless hb3.bridge_name == "pwnbr-2"
puts "  ✓ Test 6: second allocation (kind=ovs) gets short_id=2, bridge_name=pwnbr-2"

# ── Test 7: AASM lifecycle ────────────────────────────────────────────

hb.start_drain!
abort("  ❌ Test 7a FAILED — state didn't transition to draining") unless hb.reload.state == "draining"
hb.mark_removed!
abort("  ❌ Test 7b FAILED — state didn't transition to removed") unless hb.reload.state == "removed"

# Removed bridge is excluded from compilable scope.
remaining = ::Sdwan::TopologyCompiler.host_bridges_for(instance).map { |b| b[:name] }
abort("  ❌ Test 7c FAILED — removed bridge still in compilable list") if remaining.include?("pwnbr-1")
puts "  ✓ Test 7: AASM transitions active -> draining -> removed; removed excluded from compile"

# ── Test 8: Re-allocate readopts the removed row ──────────────────────

hb_readopt = ::Sdwan::HostBridgeAllocator.allocate!(host: instance, kind: "linux")
abort("  ❌ Test 8 FAILED — readopt returned new row instead of reviving") unless hb_readopt.id == hb.id
abort("  ❌ Test 8 FAILED — readopted row not active (state=#{hb_readopt.state})") unless hb_readopt.state == "active"
puts "  ✓ Test 8: re-allocating same kind readopts the removed row (back to active)"

# ── Cleanup ───────────────────────────────────────────────────────────

if ENV["SMOKE_KEEP"] != "1"
  ::Sdwan::HostBridge.where(node_instance_id: instance.id).destroy_all
  instance.destroy
  node.destroy
  puts ""
  puts "  Cleanup: removed smoke fixtures (set SMOKE_KEEP=1 to preserve)"
end

puts ""
puts "  ✅ All O1 smoke tests passed."
