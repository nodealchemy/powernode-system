# frozen_string_literal: true

# System extension — Smoke-test for the DR replace lane (APO-4 / DR-1,
# IMP-555db48d41f1).
#
# DB-level integration test: builds a pool with one CLAIMED member standing in
# for the unrecoverable instance and one READY warm spare, attaches a volume
# and an SDWAN peer holding a VIP to the failed member, then drives the REAL
# System::Ai::Skills::ReplaceInstanceExecutor end to end — the same object
# graph and entry point System::Fleet::DecisionEngine uses when
# InstanceUnrecoverableSensor fires.
#
# WHAT IT PROVES that the specs cannot: the executor composes against the
# LIVE object graph (a real InstancePool, real ProviderVolume rows, a real
# Sdwan::Network with a real PeerEnroller run behind it) rather than against
# factory-built stand-ins, and the four steps agree with each other in that
# graph — the acquire's member is the one the volume lands on, and the peer
# the enroller mints is the one the VIP moves to.
#
# THE PROVIDER IS MOCKED, DELIBERATELY. Volume attach/detach and the reap are
# provider-side verbs; a smoke seed must not ask a real hypervisor to move
# disks. System::Providers::Registry is stubbed to a MockProvider for the
# duration of the run and restored in the ensure block, so nothing outside
# this file sees the swap.
#
# NOTHING IS TERMINATED. The reap is a separate approval on
# system.instance_reap and this run never asks for it (`reap:` is left at its
# default false), which is itself asserted below: a replace that quietly
# terminated would be the exact defect the split gate exists to prevent.
#
# Safe to run repeatedly: fixtures are named `smoke-replace-*`, wiped at the
# top of the run and removed again at the end unless SMOKE_KEEP=1.
#
# Invoke:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_instance_replace.rb')"

puts "\n  Smoke-test: DR instance replace (system.instance_unrecoverable → ReplaceInstanceExecutor)"
puts "  " + ("=" * 60)

account  = Account.first or abort("  ❌ No account in DB")
template = System::NodeTemplate.find_by(account: account, name: "base") ||
           System::NodeTemplate.where(account: account).first ||
           abort("  ❌ No node template — run node_module_catalog.rb first")
provider = System::Provider.find_by(account: account, provider_type: "local_qemu") ||
           System::Provider.where(account: account).first ||
           abort("  ❌ No provider")
region   = provider.provider_regions.first or abort("  ❌ No provider region")
itype    = provider.provider_instance_types.first or abort("  ❌ No instance type")

# ── Wipe any previous run ─────────────────────────────────────────────

prior_pool = System::InstancePool.find_by(account: account, name: "smoke-replace-pool")
if prior_pool
  System::ProviderVolume.where(account: account, name: "smoke-replace-volume").destroy_all
  prior_instances = System::NodeInstance.where(instance_pool_id: prior_pool.id).to_a
  ::Sdwan::Peer.where(node_instance_id: prior_instances.map(&:id)).destroy_all
  # BOTH columns, not just the pool id: chk_node_instances_pool_consistency
  # requires instance_pool_id and pool_state to be null or non-null together,
  # so clearing one alone is a CheckViolation.
  prior_instances.each { |i| i.update_columns(instance_pool_id: nil, pool_state: nil) }
  prior_pool.destroy
end
::Sdwan::Network.where(account: account, name: "smoke-replace-network").each do |n|
  ::Sdwan::VirtualIp.where(network: n).destroy_all
  ::Sdwan::Peer.where(network: n).destroy_all
  n.destroy
end
System::NodeInstance.where(account: account).where("name LIKE ?", "smoke-replace-%").destroy_all
System::Node.where(account: account).where("name LIKE ?", "smoke-replace-%").destroy_all

# ── Fixtures ──────────────────────────────────────────────────────────

pool = System::InstancePool.create!(
  account: account, node_template: template, name: "smoke-replace-pool",
  target_size: 2, min_size: 1, max_size: 4, lifecycle_class: "ephemeral",
  status: "active", provider_region: region, provider_instance_type: itype
)

def smoke_member!(account:, template:, region:, itype:, pool:, name:, pool_state:, status:)
  node = System::Node.create!(account: account, node_template: template, name: "#{name}-node")
  instance = System::NodeInstance.new(
    node: node, account: account, name: name, variety: "cloud",
    provider_region: region, provider_instance_type: itype, status: status
  )
  instance.cloud_instance_id = "mock-#{SecureRandom.hex(6)}"
  instance.save!
  instance.update!(instance_pool_id: pool.id, pool_state: pool_state,
                   pool_warming_started_at: 5.minutes.ago)
  instance
end

failed = smoke_member!(account: account, template: template, region: region, itype: itype,
                       pool: pool, name: "smoke-replace-failed",
                       pool_state: "claimed", status: "error")
spare  = smoke_member!(account: account, template: template, region: region, itype: itype,
                       pool: pool, name: "smoke-replace-spare",
                       pool_state: "ready", status: "running")

volume = System::ProviderVolume.create!(
  account: account, provider_region: region, name: "smoke-replace-volume",
  size_gb: 10, status: "in-use", external_id: "vol-#{SecureRandom.hex(6)}",
  node_instance: failed
)

network = ::Sdwan::Network.create!(
  account: account, name: "smoke-replace-network",
  slug: "smoke-replace-network",
  cidr_64: "fd00:beef:d12e:#{rand(0x1000..0xffff).to_s(16)}::/64",
  routing_protocol: "static", status: "registered"
)
old_peer = ::Sdwan::PeerEnroller.call(network: network, node_instance: failed)
vip = ::Sdwan::VirtualIp.create!(
  account: account, network: network, name: "smoke-replace-vip",
  cidr: "fd00:beef:d12e:ffff::1/128", holder_peer_ids: [ old_peer.id ]
)

puts "  Fixtures: pool=#{pool.name} failed=#{failed.name} spare=#{spare.name} " \
     "volume=#{volume.name} peer=#{old_peer.id} vip=#{vip.cidr}"

# ── Mock provider (restored in ensure) ────────────────────────────────

mock = System::Providers::MockProvider.allocate
mock.define_singleton_method(:detach_volume) { |_id, force: false| { success: true } }
mock.define_singleton_method(:attach_volume) { |_v, _i, device: nil| { success: true, device: device || "/dev/sdf" } }
mock.define_singleton_method(:terminate_instance) { |_id, expected_name: nil| { success: true } }

registry = System::Providers::Registry
registry.singleton_class.send(:alias_method, :__smoke_orig_for_volume, :for_volume)
registry.singleton_class.send(:alias_method, :__smoke_orig_for_instance, :for_instance)
registry.define_singleton_method(:for_volume) { |_volume| mock }
registry.define_singleton_method(:for_instance) { |_instance| mock }

begin
  operation_id = "smoke-replace-#{SecureRandom.hex(4)}"

  # ── Test 1 — the dry run PLANS without touching anything ─────────────

  preview = System::Ai::Skills::ReplaceInstanceExecutor
              .new(account: account)
              .execute(gated: true, instance_id: failed.id, operation_id: operation_id, dry_run: true)
  abort("  ❌ Test 1 FAILED — dry run returned success: false (#{preview[:error]})") unless preview[:success]
  abort("  ❌ Test 1 FAILED — plan did not name the stranded volume") \
    unless preview[:data][:would_reattach_volume_ids] == [ volume.id ]
  abort("  ❌ Test 1 FAILED — plan did not name the VIP") \
    unless preview[:data][:would_move_virtual_ip_ids] == [ vip.id ]
  abort("  ❌ Test 1 FAILED — dry run claimed a pool member") \
    unless spare.reload.pool_state == "ready"
  puts "  ✓ Test 1: dry run plans volumes + VIPs and claims nothing"

  # ── Test 2 — the additive half applies as one unit ───────────────────

  result = System::Ai::Skills::ReplaceInstanceExecutor
             .new(account: account)
             .execute(gated: true, instance_id: failed.id, operation_id: operation_id)
  abort("  ❌ Test 2 FAILED — replace returned success: false (#{result[:error]})") unless result[:success]
  abort("  ❌ Test 2 FAILED — did not acquire the warm spare (got #{result[:data][:replacement_instance_id]})") \
    unless result[:data][:replacement_instance_id] == spare.id
  abort("  ❌ Test 2 FAILED — spare was not claimed out of the pool") \
    unless spare.reload.pool_state == "claimed"
  abort("  ❌ Test 2 FAILED — volume did not follow the workload") \
    unless volume.reload.node_instance_id == spare.id
  new_peer = ::Sdwan::Peer.find_by(sdwan_network_id: network.id, node_instance_id: spare.id)
  abort("  ❌ Test 2 FAILED — replacement was not re-enrolled on the network") unless new_peer
  abort("  ❌ Test 2 FAILED — VIP did not move to the replacement's peer (#{vip.reload.holder_peer_ids})") \
    unless vip.reload.holder_peer_ids == [ new_peer.id ]
  abort("  ❌ Test 2 FAILED — replace reported partial: #{result[:data][:failures]}") \
    if result[:data][:partial]
  puts "  ✓ Test 2: acquire → reattach volume → re-enrol SDWAN → move VIP applied as one unit"

  # ── Test 3 — nothing was reaped ──────────────────────────────────────

  abort("  ❌ Test 3 FAILED — replace reported reaped: true without a separate approval") \
    if result[:data][:reaped]
  abort("  ❌ Test 3 FAILED — the failed instance was terminated inline") \
    if failed.reload.status == "terminated"
  puts "  ✓ Test 3: the failed instance is still alive — the reap is a separate approval"

  # ── Test 4 — idempotent on operation_id ──────────────────────────────

  claimed_before = System::NodeInstance.where(instance_pool_id: pool.id, pool_state: "claimed").count
  replay = System::Ai::Skills::ReplaceInstanceExecutor
             .new(account: account)
             .execute(gated: true, instance_id: failed.id, operation_id: operation_id)
  abort("  ❌ Test 4 FAILED — replay returned success: false (#{replay[:error]})") unless replay[:success]
  abort("  ❌ Test 4 FAILED — replay did not report the acquire as replayed") \
    unless Array(replay[:data][:replayed_steps]).include?("acquire_replacement")
  abort("  ❌ Test 4 FAILED — replay named a different replacement") \
    unless replay[:data][:replacement_instance_id] == spare.id
  abort("  ❌ Test 4 FAILED — replay claimed another pool member") \
    unless System::NodeInstance.where(instance_pool_id: pool.id, pool_state: "claimed").count == claimed_before
  puts "  ✓ Test 4: re-driving the same operation_id replays every step and claims nothing new"

  # ── Test 5 — the step ledger is readable ─────────────────────────────

  kinds = System::FleetEvent.where(account_id: account.id)
                            .where("payload->>'operation_id' = ?", operation_id)
                            .pluck(:kind).uniq.sort
  expected = %w[
    system.instance_replace.acquire_replacement
    system.instance_replace.move_vips
    system.instance_replace.reattach_volumes
    system.instance_replace.reenrol_sdwan
  ]
  abort("  ❌ Test 5 FAILED — step ledger is #{kinds.inspect}, expected #{expected.inspect}") \
    unless kinds == expected
  puts "  ✓ Test 5: one FleetEvent per step, all stamped with the operation_id"
ensure
  registry.singleton_class.send(:remove_method, :for_volume)
  registry.singleton_class.send(:remove_method, :for_instance)
  registry.singleton_class.send(:alias_method, :for_volume, :__smoke_orig_for_volume)
  registry.singleton_class.send(:alias_method, :for_instance, :__smoke_orig_for_instance)
  registry.singleton_class.send(:remove_method, :__smoke_orig_for_volume)
  registry.singleton_class.send(:remove_method, :__smoke_orig_for_instance)
end

# ── Cleanup ───────────────────────────────────────────────────────────

if ENV["SMOKE_KEEP"] != "1"
  System::FleetEvent.where(account_id: account.id)
                    .where("kind LIKE ?", "system.instance_replace.%")
                    .where("payload->>'operation_id' LIKE ?", "smoke-replace-%").destroy_all
  System::ProviderVolume.where(account: account, name: "smoke-replace-volume").destroy_all
  ::Sdwan::VirtualIp.where(network: network).destroy_all
  ::Sdwan::Peer.where(network: network).destroy_all
  network.destroy
  # Both pool columns together — see the wipe block above.
  [ failed, spare ].each { |i| i.reload.update_columns(instance_pool_id: nil, pool_state: nil) }
  pool.destroy
  [ failed, spare ].each { |i| node = i.node; i.destroy; node.destroy }
  puts ""
  puts "  Cleanup: removed smoke fixtures (set SMOKE_KEEP=1 to preserve)"
end

puts ""
puts "  ✅ All DR instance-replace smoke tests passed."
