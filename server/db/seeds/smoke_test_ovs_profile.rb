# frozen_string_literal: true

# System extension — Smoke-test for Phase O2 (network_profile +
# OvsBridgeApplier dual-stack).
#
# DB-level integration test: verifies the platform compiles
# profile-appropriate bridge kinds. Heavyweight hosts get
# kind="ovs" by default; lightweight hosts get kind="linux";
# explicit kind override always wins. The agent's two
# BridgeAppliers each filter by Kind, so this test confirms the
# server emits the right Kind for each profile — the agent's Go
# tests cover the kind-filter behavior on the consumer side.
#
# Invoke:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_ovs_profile.rb')"

puts "\n  Smoke-test: Phase O2 — network_profile + OvsBridgeApplier"
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

heavy = make_host(account: account, template: template, region: region, itype: itype,
                  name: "smoke-ovs-heavy", profile: "heavyweight")
light = make_host(account: account, template: template, region: region, itype: itype,
                  name: "smoke-ovs-light", profile: "lightweight")

puts "  Heavyweight host: #{heavy.id[0..7]}…  profile=#{heavy.network_profile}"
puts "  Lightweight host: #{light.id[0..7]}…  profile=#{light.network_profile}"
puts ""

# ── Test 1: Heavyweight default kind = ovs ────────────────────────────

hb_heavy = ::Sdwan::HostBridgeAllocator.allocate!(host: heavy)
abort("  ❌ Test 1 FAILED — heavyweight got kind=#{hb_heavy.kind} (expected ovs)") unless hb_heavy.kind == "ovs"
puts "  ✓ Test 1: heavyweight host gets kind=ovs by default"

# ── Test 2: Lightweight default kind = linux ──────────────────────────

hb_light = ::Sdwan::HostBridgeAllocator.allocate!(host: light)
abort("  ❌ Test 2 FAILED — lightweight got kind=#{hb_light.kind} (expected linux)") unless hb_light.kind == "linux"
puts "  ✓ Test 2: lightweight host gets kind=linux by default"

# ── Test 3: Explicit kind override wins ───────────────────────────────

# Force a second allocation on heavyweight, but explicitly demand linux.
hb_override = ::Sdwan::HostBridgeAllocator.allocate!(host: heavy, kind: "linux")
abort("  ❌ Test 3 FAILED — explicit kind=linux on heavyweight got #{hb_override.kind}") unless hb_override.kind == "linux"
puts "  ✓ Test 3: explicit kind override wins on heavyweight (kind=linux)"

# ── Test 4: TopologyCompiler stamps the Kind that the agent will read ─

[hb_heavy, hb_override, hb_light].each(&:mark_active!)

heavy_payload = ::Sdwan::TopologyCompiler.host_bridges_for(heavy)
light_payload = ::Sdwan::TopologyCompiler.host_bridges_for(light)

heavy_kinds = heavy_payload.map { |b| b[:kind] }.sort
light_kinds = light_payload.map { |b| b[:kind] }.sort

abort("  ❌ Test 4 FAILED — heavyweight payload kinds were #{heavy_kinds.inspect}") unless heavy_kinds == %w[linux ovs]
abort("  ❌ Test 4 FAILED — lightweight payload kinds were #{light_kinds.inspect}") unless light_kinds == %w[linux]
puts "  ✓ Test 4: TopologyCompiler emits correct Kind per payload"
puts "             heavy → #{heavy_kinds.join(', ')}"
puts "             light → #{light_kinds.join(', ')}"

# ── Test 5: NodeInstance#suggest_network_profile is callable ──────────

# Pure function — should not mutate, just return a recommendation.
heavy_suggestion = heavy.suggest_network_profile
light_suggestion = light.suggest_network_profile
abort("  ❌ Test 5 FAILED — suggest_network_profile not implemented") if heavy_suggestion.nil?
puts "  ✓ Test 5: NodeInstance#suggest_network_profile returns a value (heavy=#{heavy_suggestion.inspect}, light=#{light_suggestion.inspect})"

# ── Cleanup ───────────────────────────────────────────────────────────

if ENV["SMOKE_KEEP"] != "1"
  [heavy, light].each do |inst|
    ::Sdwan::HostBridge.where(node_instance_id: inst.id).destroy_all
    inst.destroy
    inst.node.destroy
  end
  puts ""
  puts "  Cleanup: removed smoke fixtures (set SMOKE_KEEP=1 to preserve)"
end

puts ""
puts "  ✅ All O2 smoke tests passed."
