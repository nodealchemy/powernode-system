# frozen_string_literal: true

# System extension — Smoke-test for Phase O3 (OVN models + compiler +
# topology integration).
#
# DB-level integration test: verifies the platform compiles OVN intent
# end-to-end and stamps the right ovn_control payload per host based
# on network_profile. Pairs with the agent's Go-level
# OvnControllerApplier tests; together they cover the full server ->
# wire -> agent contract for OVN bring-up. Does NOT spawn ovn-northd
# or ovn-controller — that's a Phase O3.5/O4 PoC.
#
# Invoke:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_ovn_models.rb')"

puts "\n  Smoke-test: Phase O3 — OVN Models + OvnCompiler + Topology"
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
  instance
end

# Wipe prior smoke fixtures
::Sdwan::OvnLogicalSwitchPort.where(account_id: account.id).destroy_all
::Sdwan::OvnLogicalSwitch.where(account_id: account.id).destroy_all
::Sdwan::OvnDeployment.where(account_id: account.id).destroy_all

heavy = make_host(account: account, template: template, region: region, itype: itype,
                  name: "smoke-ovn-heavy", profile: "heavyweight")
light = make_host(account: account, template: template, region: region, itype: itype,
                  name: "smoke-ovn-light", profile: "lightweight")

puts "  Account:  #{account.id[0..7]}…"
puts "  Heavy host: #{heavy.id[0..7]}…  profile=#{heavy.network_profile}"
puts "  Light host: #{light.id[0..7]}…  profile=#{light.network_profile}"
puts ""

# ── Test 1: OvnDeployment can be created and activated ────────────────

deployment = ::Sdwan::OvnDeployment.create!(
  account: account,
  nb_db_endpoint: "tcp:10.0.0.1:6641",
  sb_db_endpoint: "tcp:10.0.0.1:6642",
  northd_host: "ovn-central-01"
)
# AASM: pending → bootstrapping → active. Event names are
# start_bootstrap and mark_active.
deployment.start_bootstrap!
deployment.mark_active!
deployment.reload
abort("  ❌ Test 1 FAILED — deployment not active (status=#{deployment.status})") unless deployment.status == "active"
puts "  ✓ Test 1: OvnDeployment created and transitioned to active"

# ── Test 2: LogicalSwitch + Port can be created ───────────────────────

ls = ::Sdwan::OvnLogicalSwitch.create!(
  account: account,
  deployment: deployment,
  name: "ls-smoke-test",
  cidr: "10.10.0.0/24",
  description: "smoke test logical switch"
)
ls.mark_active!

lsp1 = ::Sdwan::OvnLogicalSwitchPort.create!(
  account: account,
  logical_switch: ls,
  host_node_instance: heavy,
  name: "lsp-vm-001",
  addresses: ["10.10.0.5"],
  kind: "vm"
)
lsp1.mark_active!

abort("  ❌ Test 2 FAILED — LogicalSwitch not active (state=#{ls.reload.state})") unless ls.state == "active"
abort("  ❌ Test 2 FAILED — LogicalSwitchPort missing MAC") if lsp1.mac.blank?
abort("  ❌ Test 2 FAILED — MAC doesn't have 02: prefix (#{lsp1.mac})") unless lsp1.mac.start_with?("02:")
puts "  ✓ Test 2: LogicalSwitch + Port created (mac auto-gen=#{lsp1.mac})"

# ── Test 3: OvnCompiler emits structured plan ─────────────────────────

result = ::Sdwan::OvnCompiler.compile_for_deployment(deployment)
abort("  ❌ Test 3 FAILED — compiler returned nil") if result.nil?
abort("  ❌ Test 3 FAILED — :plan missing") unless result[:plan].is_a?(Array)
abort("  ❌ Test 3 FAILED — plan empty") if result[:plan].empty?

ls_add_entries = result[:plan].select { |e| e[:cmd] == "ls-add" }
lsp_add_entries = result[:plan].select { |e| e[:cmd] == "lsp-add" }
abort("  ❌ Test 3 FAILED — no ls-add in plan") if ls_add_entries.empty?
abort("  ❌ Test 3 FAILED — no lsp-add in plan") if lsp_add_entries.empty?

# Switches should appear before their ports (dependency ordering).
ls_idx = result[:plan].index { |e| e[:cmd] == "ls-add" }
lsp_idx = result[:plan].index { |e| e[:cmd] == "lsp-add" }
abort("  ❌ Test 3 FAILED — lsp-add precedes ls-add (#{lsp_idx} < #{ls_idx})") unless lsp_idx > ls_idx
puts "  ✓ Test 3: OvnCompiler plan has #{result[:plan].length} entries; switches precede ports"

# ── Test 4: Re-compile produces byte-identical plan ───────────────────

result2 = ::Sdwan::OvnCompiler.compile_for_deployment(deployment)
abort("  ❌ Test 4 FAILED — re-compile not idempotent") unless result[:plan] == result2[:plan]
puts "  ✓ Test 4: re-compile produces byte-identical plan (idempotent)"

# ── Test 5: TopologyCompiler.ovn_control_for — heavyweight ────────────

# Heavy host needs at least one Sdwan::Peer for the encap_ip derivation.
network = ::Sdwan::Network.find_or_create_by!(account: account, name: "smoke-ovn-network") do |n|
  n.cidr_64 = "fd00:dead:beef:ee00::/64"
  n.routing_protocol = "static"
end
::Sdwan::Peer.where(network: network, node_instance: heavy).destroy_all
peer = ::Sdwan::PeerEnroller.call(network: network, node_instance: heavy)

ovn_control = ::Sdwan::TopologyCompiler.ovn_control_for(heavy)
abort("  ❌ Test 5 FAILED — ovn_control nil for heavyweight w/ active deployment") if ovn_control.nil?
abort("  ❌ Test 5 FAILED — sb_db_endpoint missing") unless ovn_control[:sb_db_endpoint] == "tcp:10.0.0.1:6642"
abort("  ❌ Test 5 FAILED — encap_type wrong (#{ovn_control[:encap_type]})") unless ovn_control[:encap_type] == "geneve"
abort("  ❌ Test 5 FAILED — encap_ip empty") if ovn_control[:encap_ip].blank?
abort("  ❌ Test 5 FAILED — encap_ip wrong (#{ovn_control[:encap_ip]})") unless ovn_control[:encap_ip] == peer.assigned_address.to_s.split("/").first
puts "  ✓ Test 5: heavyweight host gets ovn_control payload (encap_ip=#{ovn_control[:encap_ip]})"

# ── Test 6: TopologyCompiler.ovn_control_for — lightweight ────────────

light_ctrl = ::Sdwan::TopologyCompiler.ovn_control_for(light)
abort("  ❌ Test 6 FAILED — lightweight host got non-nil ovn_control") unless light_ctrl.nil?
puts "  ✓ Test 6: lightweight host gets nil ovn_control (skip-OVN signal)"

# ── Test 7: ovn_control nil when no active deployment ─────────────────

deployment.update!(status: "degraded")
ctrl_no_active = ::Sdwan::TopologyCompiler.ovn_control_for(heavy)
abort("  ❌ Test 7 FAILED — non-active deployment yielded ovn_control") unless ctrl_no_active.nil?
deployment.update!(status: "active")  # restore
puts "  ✓ Test 7: heavyweight + degraded deployment → ovn_control nil"

# ── Cleanup ───────────────────────────────────────────────────────────

if ENV["SMOKE_KEEP"] != "1"
  ::Sdwan::OvnLogicalSwitchPort.where(account_id: account.id).destroy_all
  ::Sdwan::OvnLogicalSwitch.where(account_id: account.id).destroy_all
  ::Sdwan::OvnDeployment.where(account_id: account.id).destroy_all
  ::Sdwan::Peer.where(network: network).destroy_all
  network.destroy
  [heavy, light].each do |inst|
    inst.destroy
    inst.node.destroy
  end
  puts ""
  puts "  Cleanup: removed smoke fixtures (set SMOKE_KEEP=1 to preserve)"
end

puts ""
puts "  ✅ All O3 smoke tests passed."
