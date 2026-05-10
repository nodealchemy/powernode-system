# frozen_string_literal: true

# System extension — Smoke-test for Phase O5 (IPFIX telemetry pipeline).
#
# DB-level integration test: verifies the platform stamps an `ipfix:`
# block on each ovs-kind HostBridge entry when an active IpfixCollector
# exists for the account, and skips it for linux-kind bridges. The
# agent's OvsBridgeApplier consumes the field via reconcileIpfix; this
# smoke validates the wire shape, not the actual ovs-vsctl execution.
#
# Invoke:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_ipfix_telemetry.rb')"

puts "\n  Smoke-test: Phase O5 — IPFIX Telemetry Pipeline"
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

def make_host(account:, template:, region:, itype:, name:, profile:)
  node = System::Node.find_or_create_by!(account: account, name: name) do |n|
    n.node_template = template
  end
  instance = System::NodeInstance.find_or_initialize_by(node: node, name: "#{name}-instance")
  instance.assign_attributes(
    variety: "cloud",
    provider_region: region,
    provider_instance_type: itype,
    status: "running",
    network_profile: profile
  )
  instance.save!
  ::Sdwan::HostBridge.where(node_instance_id: instance.id).destroy_all
  instance
end

# Wipe prior smoke fixtures
::Sdwan::IpfixCollector.where(account_id: account.id).where("name LIKE 'smoke-ipfix-%'").destroy_all

heavy = make_host(account: account, template: template, region: region, itype: itype,
                  name: "smoke-ipfix-heavy", profile: "heavyweight")
light = make_host(account: account, template: template, region: region, itype: itype,
                  name: "smoke-ipfix-light", profile: "lightweight")

puts "  Account:  #{account.id[0..7]}…"
puts "  Heavy host: #{heavy.id[0..7]}…  profile=#{heavy.network_profile}"
puts "  Light host: #{light.id[0..7]}…  profile=#{light.network_profile}"
puts ""

# ── Allocate bridges (heavy → ovs, light → linux) via the existing allocator

ovs_bridge   = ::Sdwan::HostBridgeAllocator.allocate!(host: heavy)
linux_bridge = ::Sdwan::HostBridgeAllocator.allocate!(host: light)
ovs_bridge.mark_active!
linux_bridge.mark_active!

abort("  ❌ Setup FAILED — heavy bridge kind=#{ovs_bridge.kind} (expected ovs)") unless ovs_bridge.kind == "ovs"
abort("  ❌ Setup FAILED — light bridge kind=#{linux_bridge.kind} (expected linux)") unless linux_bridge.kind == "linux"
puts "  Heavy bridge: #{ovs_bridge.bridge_name} (kind=ovs)"
puts "  Light bridge: #{linux_bridge.bridge_name} (kind=linux)"

# ── Test 1: With NO active collector, no ipfix block on either bridge

heavy_payload = ::Sdwan::TopologyCompiler.host_bridges_for(heavy)
light_payload = ::Sdwan::TopologyCompiler.host_bridges_for(light)

abort("  ❌ Test 1 FAILED — heavy payload empty") if heavy_payload.empty?
abort("  ❌ Test 1 FAILED — heavy entry has unexpected ipfix without collector") if heavy_payload.first.key?(:ipfix)
abort("  ❌ Test 1 FAILED — light entry has unexpected ipfix without collector") if light_payload.first.key?(:ipfix)
puts "  ✓ Test 1: no IpfixCollector → no :ipfix key on any bridge entry"

# ── Test 2: Active collector → :ipfix on ovs bridges only ────────────

collector = ::Sdwan::IpfixCollector.create!(
  account: account,
  name: "smoke-ipfix-primary",
  host: "10.0.0.1",
  port: 4739,
  sampling_rate: 64
)
abort("  ❌ Test 2 setup FAILED — collector not active") unless collector.state == "active"

heavy_with_ipfix = ::Sdwan::TopologyCompiler.host_bridges_for(heavy)
light_with_ipfix = ::Sdwan::TopologyCompiler.host_bridges_for(light)

heavy_entry = heavy_with_ipfix.first
abort("  ❌ Test 2 FAILED — ovs bridge missing :ipfix") unless heavy_entry.key?(:ipfix)
abort("  ❌ Test 2 FAILED — :ipfix targets wrong (#{heavy_entry[:ipfix][:targets].inspect})") unless heavy_entry[:ipfix][:targets] == ["10.0.0.1:4739"]
abort("  ❌ Test 2 FAILED — :ipfix sampling wrong (#{heavy_entry[:ipfix][:sampling]})") unless heavy_entry[:ipfix][:sampling] == 64
puts "  ✓ Test 2: ovs bridge gets :ipfix (targets=#{heavy_entry[:ipfix][:targets].inspect}, sampling=#{heavy_entry[:ipfix][:sampling]})"

light_entry = light_with_ipfix.first
abort("  ❌ Test 2 FAILED — linux bridge unexpectedly got :ipfix") if light_entry.key?(:ipfix)
puts "  ✓ Test 2: linux bridge correctly skipped (no :ipfix key)"

# ── Test 3: IPv6 collector renders bracketed target ───────────────────

collector.update!(host: "fd00::1")
heavy_v6 = ::Sdwan::TopologyCompiler.host_bridges_for(heavy)
abort("  ❌ Test 3 FAILED — IPv6 not bracketed (#{heavy_v6.first[:ipfix][:targets].inspect})") unless heavy_v6.first[:ipfix][:targets] == ["[fd00::1]:4739"]
puts "  ✓ Test 3: IPv6 collector renders as bracketed target [fd00::1]:4739"

# ── Test 4: Disabled collector → no ipfix block ───────────────────────

collector.disable!
heavy_disabled = ::Sdwan::TopologyCompiler.host_bridges_for(heavy)
abort("  ❌ Test 4 FAILED — disabled collector still emitting ipfix") if heavy_disabled.first.key?(:ipfix)
puts "  ✓ Test 4: disabled collector → no :ipfix key (skip-IPFIX signal)"

# ── Test 5: Re-enable picks up the latest collector again ─────────────

collector.enable!
heavy_renabled = ::Sdwan::TopologyCompiler.host_bridges_for(heavy)
abort("  ❌ Test 5 FAILED — re-enabled collector not reflected") unless heavy_renabled.first.key?(:ipfix)
puts "  ✓ Test 5: re-enabling collector → :ipfix re-emitted"

# ── Cleanup ───────────────────────────────────────────────────────────

if ENV["SMOKE_KEEP"] != "1"
  ::Sdwan::IpfixCollector.where(account_id: account.id).where("name LIKE 'smoke-ipfix-%'").destroy_all
  ::Sdwan::HostBridge.where(node_instance_id: [heavy.id, light.id]).destroy_all
  [heavy, light].each do |inst|
    inst.destroy
    inst.node.destroy
  end
  puts ""
  puts "  Cleanup: removed smoke fixtures (set SMOKE_KEEP=1 to preserve)"
end

puts ""
puts "  ✅ All O5 smoke tests passed."
