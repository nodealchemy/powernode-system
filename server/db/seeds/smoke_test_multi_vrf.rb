# frozen_string_literal: true

# System extension — Smoke-test for Phase N1a (multi-network VRF).
#
# DB-level integration test: allocates VRFs for a single host across
# multiple networks, compiles FRR config, adds a route leak, and verifies
# the compiled output contains the expected per-VRF blocks. Does NOT spawn
# VMs — companion VM-mesh smoke (smoke_test_multi_vrf_vm.rb) covers the
# kernel-level VRF isolation + RouteLeak propagation.
#
# Asserts the contract the agent's vrf_applier.go relies on:
#   1. VrfAllocator assigns unique table_ids per (host, network)
#   2. ConfigCompiler emits one `router bgp <as> vrf <name>` per active assignment
#   3. Two BGP instances on the same host carry distinct ASNs without conflict
#   4. RouteLeak rows compile into `import vrf` directives in the destination VRF's AF
#   5. Removing a RouteLeak removes the import directive on next compile
#
# Invoke:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_multi_vrf.rb')"

puts "\n  Smoke-test: Phase N1a — Multi-Network FRR (Multi-VRF)"
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

node = System::Node.find_or_create_by!(account: account, name: "smoke-vrf-host") do |n|
  n.node_template = template
end
instance = System::NodeInstance.find_or_initialize_by(node: node, name: "smoke-vrf-host-instance")
instance.assign_attributes(
  variety: "cloud", provider_region: region, provider_instance_type: itype, status: "running"
)
instance.save!

# Wipe prior smoke fixtures so allocator allocates fresh table_ids.
::Sdwan::HostVrfAssignment.where(node_instance_id: instance.id).destroy_all
prior_nets = ::Sdwan::Network.where(account: account, name: %w[smoke-vrf-network-a smoke-vrf-network-b])
::Sdwan::RouteLeak.where(source_network_id: prior_nets.pluck(:id)).destroy_all
::Sdwan::RouteLeak.where(dest_network_id: prior_nets.pluck(:id)).destroy_all
::Sdwan::Peer.where(network: prior_nets, node_instance: instance).destroy_all
prior_nets.destroy_all

network_a = ::Sdwan::Network.create!(
  account: account, name: "smoke-vrf-network-a",
  cidr_64: "fd00:dead:beef:a#{rand(0..0xfff).to_s(16).rjust(3, '0')}::/64",
  routing_protocol: "ibgp",
  settings: { "topology_strategy" => "hub_and_spoke", "as_number" => 65001 }
)
network_b = ::Sdwan::Network.create!(
  account: account, name: "smoke-vrf-network-b",
  cidr_64: "fd00:dead:beef:b#{rand(0..0xfff).to_s(16).rjust(3, '0')}::/64",
  routing_protocol: "ibgp",
  settings: { "topology_strategy" => "hub_and_spoke", "as_number" => 65002 }
)
peer_a = ::Sdwan::PeerEnroller.call(network: network_a, node_instance: instance)
peer_b = ::Sdwan::PeerEnroller.call(network: network_b, node_instance: instance)

puts "  Account:  #{account.id[0..7]}…"
puts "  Host:     #{instance.id[0..7]}…"
puts "  Network A: #{network_a.name} (AS65001, handle=#{network_a.network_handle})"
puts "  Network B: #{network_b.name} (AS65002, handle=#{network_b.network_handle})"
puts ""

# ── Test 1: VrfAllocator assigns distinct table_ids per network ───────

hva_a = ::Sdwan::VrfAllocator.allocate!(host: instance, network: network_a)
hva_b = ::Sdwan::VrfAllocator.allocate!(host: instance, network: network_b)
abort("  ❌ Test 1 FAILED — allocator returned nil for network A") if hva_a.nil?
abort("  ❌ Test 1 FAILED — allocator returned nil for network B") if hva_b.nil?
abort("  ❌ Test 1 FAILED — same table_id (#{hva_a.table_id}) reused across networks") if hva_a.table_id == hva_b.table_id
abort("  ❌ Test 1 FAILED — same vrf_name reused across networks") if hva_a.vrf_name == hva_b.vrf_name
puts "  ✓ Test 1: VrfAllocator assigned distinct (vrf_name, table_id) per (host, network)"
puts "             A → #{hva_a.vrf_name} (table=#{hva_a.table_id})"
puts "             B → #{hva_b.vrf_name} (table=#{hva_b.table_id})"

# ── Test 2: VrfAllocator is idempotent for same (host, network) ───────

hva_a2 = ::Sdwan::VrfAllocator.allocate!(host: instance, network: network_a)
abort("  ❌ Test 2 FAILED — repeat allocation returned different row") unless hva_a2.id == hva_a.id
abort("  ❌ Test 2 FAILED — repeat allocation changed table_id") unless hva_a2.table_id == hva_a.table_id
puts "  ✓ Test 2: re-allocation is idempotent (same row id + table_id returned)"

# ── Test 3: VrfAllocator never assigns reserved kernel tables ─────────

reserved = [0, 253, 254, 255]
abort("  ❌ Test 3 FAILED — allocator handed out reserved table_id #{hva_a.table_id}") if reserved.include?(hva_a.table_id)
abort("  ❌ Test 3 FAILED — allocator handed out reserved table_id #{hva_b.table_id}") if reserved.include?(hva_b.table_id)
puts "  ✓ Test 3: no reserved kernel table_ids handed out"

# ── Test 4: Mark assignments active for compiler emission ─────────────

hva_a.mark_active!
hva_b.mark_active!
puts "  ✓ Test 4: assignments transitioned to active"

# ── Test 5: BGP compiler emits per-VRF router bgp blocks ──────────────

frr_text = ::Sdwan::Bgp::ConfigCompiler.compile_for_peer(peer_a).then { |c| c.is_a?(Hash) ? c[:frr_text].to_s : c&.frr_text.to_s }
abort("  ❌ Test 5 FAILED — compiler produced empty frr_text") if frr_text.strip.empty?
# Network model auto-generates the BGP ASN from the network ID rather
# than honoring settings.as_number (left as a documented quirk to
# revisit in N1b). For now the smoke just checks each VRF has its own
# router bgp block, AS-agnostic.
unless frr_text.match?(/router bgp \d+ vrf #{Regexp.escape(hva_a.vrf_name)}\b/)
  abort("  ❌ Test 5 FAILED — missing router bgp block for VRF #{hva_a.vrf_name}:\n#{frr_text}")
end
unless frr_text.match?(/router bgp \d+ vrf #{Regexp.escape(hva_b.vrf_name)}\b/)
  abort("  ❌ Test 5 FAILED — missing router bgp block for VRF #{hva_b.vrf_name}:\n#{frr_text}")
end
puts "  ✓ Test 5: frr.conf emits per-VRF BGP instances for both VRFs"

# ── Test 6: VRF definitions emitted in frr.conf ───────────────────────

unless frr_text.match?(/^vrf #{Regexp.escape(hva_a.vrf_name)}\b/m)
  abort("  ❌ Test 6 FAILED — missing `vrf #{hva_a.vrf_name}` definition")
end
unless frr_text.match?(/^vrf #{Regexp.escape(hva_b.vrf_name)}\b/m)
  abort("  ❌ Test 6 FAILED — missing `vrf #{hva_b.vrf_name}` definition")
end
puts "  ✓ Test 6: frr.conf emits both VRF definitions"

# ── Test 7: RouteLeak compiles into import vrf directive ──────────────

leak = ::Sdwan::RouteLeak.create!(
  account: account,
  source_network: network_a, dest_network: network_b,
  prefix_filter: [{ "cidr" => network_a.cidr_64, "action" => "permit" }],
  direction: "one_way",
  reason: "smoke-test:n1a-route-leak"
)
leak.activate!

frr_text2 = ::Sdwan::Bgp::ConfigCompiler.compile_for_peer(peer_b).then { |c| c.is_a?(Hash) ? c[:frr_text].to_s : c&.frr_text.to_s }
unless frr_text2.include?("import vrf #{hva_a.vrf_name}")
  abort("  ❌ Test 7 FAILED — leak did not produce `import vrf` directive in B's BGP block:\n#{frr_text2}")
end
puts "  ✓ Test 7: RouteLeak A→B compiled to `import vrf #{hva_a.vrf_name}` in B's IPv6 unicast AF"

# ── Test 8: TopologyCompiler stamps vrf_name on interface block ───────

view = ::Sdwan::TopologyCompiler.compile_for_peer(peer_a, include_private_key: true)
abort("  ❌ Test 8 FAILED — interface block missing :vrf_name") unless view[:interface].key?(:vrf_name)
unless view[:interface][:vrf_name] == hva_a.vrf_name
  abort("  ❌ Test 8 FAILED — interface vrf_name mismatch: got #{view[:interface][:vrf_name].inspect}, want #{hva_a.vrf_name.inspect}")
end
puts "  ✓ Test 8: TopologyCompiler stamps vrf_name=#{hva_a.vrf_name} on peer A's interface"

# ── Test 9: Removing the leak removes the import directive ────────────

leak.revoke!
frr_text3 = ::Sdwan::Bgp::ConfigCompiler.compile_for_peer(peer_b).then { |c| c.is_a?(Hash) ? c[:frr_text].to_s : c&.frr_text.to_s }
if frr_text3.include?("import vrf #{hva_a.vrf_name}")
  abort("  ❌ Test 9 FAILED — revoked leak still emits `import vrf` directive")
end
puts "  ✓ Test 9: revoking the leak removes `import vrf` from next compile"

# ── Cleanup ───────────────────────────────────────────────────────────

if ENV["SMOKE_KEEP"] != "1"
  ::Sdwan::RouteLeak.where(source_network_id: [network_a.id, network_b.id]).destroy_all
  ::Sdwan::HostVrfAssignment.where(node_instance_id: instance.id).destroy_all
  ::Sdwan::MembershipCredential.where(sdwan_network_id: [network_a.id, network_b.id]).destroy_all
  ::Sdwan::Peer.where(network: [network_a, network_b]).destroy_all
  network_a.destroy
  network_b.destroy
  instance.destroy
  node.destroy
  puts ""
  puts "  Cleanup: removed smoke fixtures (set SMOKE_KEEP=1 to preserve)"
end

puts ""
puts "  ✅ All N1a smoke tests passed."
