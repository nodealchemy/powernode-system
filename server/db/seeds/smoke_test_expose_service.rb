# frozen_string_literal: true

# System extension — Smoke-test for the ingress exposure surface (campaign
# 019f3458 increment 2), Path A / Path E of
# extensions/system/docs/runbooks/traefik-tcp-exposure-vs-dnat.md.
#
# DB-level integration test: enrolls a hub peer + backend peer on a fresh
# SDWAN overlay network, then drives the REAL
# System::Ai::Skills::ExposeServicePubliclyExecutor and
# System::Ai::Skills::ExposeServiceLocalExecutor end to end (no stubbing) —
# the same object graph + entry points the `system_expose_service_publicly`
# and `system_expose_service_local` MCP tools use in production.
#
# Safe to run repeatedly:
#   - The publicly-expose test uses service_protocol: "http", the executor's
#     existing no-TLS branch (expose_service_publicly_executor.rb:154 `if
#     protocol == "https"`) — this is a real, live code path, not a stub, and
#     it never calls the ACME/reverse-proxy steps, so no DNS-01 challenge or
#     live certificate issuance is required.
#   - The local-expose test overrides POWERNODE_TRAEFIK_DYNAMIC_DIR (an
#     existing, already-env-overridable setting — see
#     Acme::TraefikConfigWriter.default_dynamic_dir) to a tmp directory for
#     the duration of the run, so ServiceExposureWriter never touches the
#     real Traefik dynamic-config directory.
#   - Prior smoke fixtures (network/peers/service) are wiped at the top of
#     each section before creating fresh ones, mirroring
#     smoke_test_membership_credentials.rb / smoke_test_host_bridge.rb.
#
# Invoke:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_expose_service.rb')"

require "fileutils"

puts "\n  Smoke-test: Ingress exposure (system_expose_service_publicly / system_expose_service_local)"
puts "  " + ("=" * 60)

# ── Setup fixtures ────────────────────────────────────────────────────

account  = Account.first or abort("  ❌ No account in DB")
template = System::NodeTemplate.find_by(account: account, name: "base") ||
           System::NodeTemplate.where(account: account).first ||
           abort("  ❌ No node template — run node_module_catalog.rb first")
provider = System::Provider.find_by(account: account, provider_type: "local_qemu") ||
           abort("  ❌ No local_qemu provider")
region   = provider.provider_regions.first or abort("  ❌ No provider region")
itype    = provider.provider_instance_types.first or abort("  ❌ No instance type")

def find_or_create_instance!(account:, template:, region:, itype:, name:)
  node = System::Node.find_or_create_by!(account: account, name: "#{name}-node") do |n|
    n.node_template = template
  end
  instance = System::NodeInstance.find_or_initialize_by(node: node, name: name)
  instance.assign_attributes(variety: "cloud", provider_region: region,
                              provider_instance_type: itype, status: "running")
  instance.save!
  [ node, instance ]
end

hub_node, hub_instance         = find_or_create_instance!(account: account, template: template, region: region,
                                                            itype: itype, name: "smoke-ingress-hub-instance")
backend_node, backend_instance = find_or_create_instance!(account: account, template: template, region: region,
                                                            itype: itype, name: "smoke-ingress-backend-instance")

# Fresh network so repeated runs don't collide with a previous run's cidr_64
# (Sdwan::Network#cidr_64 is globally unique).
network = ::Sdwan::Network.find_or_create_by!(account: account, name: "smoke-ingress-network") do |n|
  n.cidr_64 = "fd00:beef:1ec5:#{rand(0x1000..0xffff).to_s(16)}::/64"
  n.routing_protocol = "static"
  n.settings = { "topology_strategy" => "hub_and_spoke" }
end

# Reset peers to a known shape for this network (idempotent re-run).
::Sdwan::Peer.where(network: network, node_instance: [ hub_instance, backend_instance ]).destroy_all

hub_peer = ::Sdwan::PeerEnroller.call(
  network: network, node_instance: hub_instance,
  publicly_reachable: true, endpoint_host_v6: "fd00:beef:1ec5::1", endpoint_port: 51_820
)
backend_peer = ::Sdwan::PeerEnroller.call(network: network, node_instance: backend_instance)

vip_prefix = network.cidr_64.sub(%r{::/64\z}, "")

puts "  Account:  #{account.id[0..7]}…"
puts "  Network:  #{network.name} (#{network.cidr_64})"
puts "  Hub peer: #{hub_peer.id[0..7]}…  addr=#{hub_peer.assigned_address}"
puts "  Backend:  #{backend_peer.id[0..7]}…  addr=#{backend_peer.assigned_address}"
puts ""

# ── Section 1: system_expose_service_publicly (http — no ACME) ────────

puts "  [system_expose_service_publicly]"

hostname = "smoke-ingress.example.test"
vip_name = "expose-#{hostname}"
::Sdwan::VirtualIp.where(network: network, name: vip_name).destroy_all
::Sdwan::PortMapping.where(sdwan_network_id: network.id, name: "expose-#{hostname}-80").destroy_all

# `gated: true` on every skill-executor call below — APO-1c (IMP-7e2bdc1774e4).
# These executors declare `requires_approval: true`, and BaseSkillExecutor
# #execute now resolves Ai::InterventionPolicy before #perform: on an install
# with no policy row the category defaults to require_approval, so an ungated
# call here would park an approval, return success: false, and abort the smoke
# run on a policy verdict rather than on anything it was written to test. An
# operator running this seed by hand IS the decision the gate exists to ask
# for, so the smoke path asserts it the same way System::Fleet::DecisionEngine
# does. Nothing else in the platform may pass this flag on an operator door.
publicly_executor = ::System::Ai::Skills::ExposeServicePubliclyExecutor.new(account: account)
result1 = publicly_executor.execute(
  gated: true,
  service_hostname: hostname, service_protocol: "http",
  sdwan_network_id: network.id, sdwan_hub_peer_id: hub_peer.id,
  vip_cidr: "#{vip_prefix}::a/128",
  target_peer_id: backend_peer.id, backend_port: 8080
)
abort("  ❌ Test 1 FAILED — execute returned success: false (#{result1[:error]})") unless result1[:success]
data1 = result1[:data]
abort("  ❌ Test 1 FAILED — no vip_id in result") if data1[:vip_id].blank?
abort("  ❌ Test 1 FAILED — no port_mapping_id in result") if data1[:port_mapping_id].blank?
abort("  ❌ Test 1 FAILED — certificate_id should be nil for http") unless data1[:certificate_id].nil?
abort("  ❌ Test 1 FAILED — public_endpoints wrong (#{data1[:public_endpoints]})") \
  unless data1[:public_endpoints] == [ "http://#{hostname}" ]
abort("  ❌ Test 1 FAILED — steps_completed wrong (#{data1[:steps_completed]})") \
  unless data1[:steps_completed] == %w[create_virtual_ip create_port_mapping]
puts "  ✓ Test 1: create-and-expose — vip=#{data1[:vip_id][0..7]}… port_mapping=#{data1[:port_mapping_id][0..7]}…"

vip = ::Sdwan::VirtualIp.find(data1[:vip_id])
abort("  ❌ Test 2 FAILED — VIP holder is not the backend peer") unless vip.holder_peer_ids == [ backend_peer.id ]
pm = ::Sdwan::PortMapping.find(data1[:port_mapping_id])
abort("  ❌ Test 2 FAILED — port mapping listen_port wrong (#{pm.listen_port})") unless pm.listen_port == 80
abort("  ❌ Test 2 FAILED — port mapping target_port wrong (#{pm.target_port})") unless pm.target_port == 8080
abort("  ❌ Test 2 FAILED — port mapping target_virtual_ip_id wrong") unless pm.target_virtual_ip_id == vip.id
puts "  ✓ Test 2: DNAT wiring correct — VIP holder=backend peer, :80 -> VIP:8080"

# Re-run: same hostname must reuse the VIP (idempotency — fix #1 regression guard).
result2 = ::System::Ai::Skills::ExposeServicePubliclyExecutor.new(account: account).execute(
  gated: true,
  service_hostname: hostname, service_protocol: "http",
  sdwan_network_id: network.id, sdwan_hub_peer_id: hub_peer.id,
  vip_cidr: "#{vip_prefix}::a/128",
  target_peer_id: backend_peer.id, backend_port: 8080
)
abort("  ❌ Test 3 FAILED — re-run returned success: false (#{result2[:error]})") unless result2[:success]
abort("  ❌ Test 3 FAILED — re-run created a second VIP instead of reusing") \
  unless result2[:data][:vip_id] == data1[:vip_id]
abort("  ❌ Test 3 FAILED — re-run's steps_completed doesn't show reuse (#{result2[:data][:steps_completed]})") \
  unless result2[:data][:steps_completed].include?("reuse_virtual_ip")
puts "  ✓ Test 3: re-running with the same hostname reuses the VIP (idempotent)"

# ── Section 2: system_expose_service_local (no ACME issuance either — only
#    reads an existing cert for host resolution, and there may be none) ────

puts ""
puts "  [system_expose_service_local]"

# Redirect the Traefik dynamic-config write to a scratch dir so this smoke
# test never touches the real /etc/traefik/dynamic (or whatever the live
# deployment has configured).
scratch_dir = Rails.root.join("tmp", "smoke-ingress-local-services")
FileUtils.mkdir_p(scratch_dir)
prior_dynamic_dir = ENV["POWERNODE_TRAEFIK_DYNAMIC_DIR"]
ENV["POWERNODE_TRAEFIK_DYNAMIC_DIR"] = scratch_dir.to_s

begin
  slug = "smoke-ingress-svc"
  ::Sdwan::Service.where(account: account, slug: slug).destroy_all

  local_executor = ::System::Ai::Skills::ExposeServiceLocalExecutor.new(account: account)
  result3 = local_executor.execute(
    gated: true,
    slug: slug, name: "Smoke Ingress Service", protocol: "https",
    backend_host: "10.99.0.5", backend_port: 3000, auth_mode: "authenticated"
  )
  abort("  ❌ Test 4 FAILED — execute returned success: false (#{result3[:error]})") unless result3[:success]
  data3 = result3[:data]
  abort("  ❌ Test 4 FAILED — created should be true") unless data3[:created] == true
  abort("  ❌ Test 4 FAILED — local_path wrong (#{data3[:local_path]})") unless data3[:local_path] == "/svc/#{slug}"
  abort("  ❌ Test 4 FAILED — routes_configured missing") if data3[:routes_configured].nil?
  written = File.join(scratch_dir, "local-services-#{account.id}.yaml")
  abort("  ❌ Test 4 FAILED — ServiceExposureWriter did not write #{written}") unless File.exist?(written)
  puts "  ✓ Test 4: create-and-expose — service=#{data3[:service_id][0..7]}… local_path=#{data3[:local_path]}"

  service = ::Sdwan::Service.find(data3[:service_id])
  abort("  ❌ Test 5 FAILED — local_enabled not set") unless service.local_enabled
  abort("  ❌ Test 5 FAILED — local_auth_mode wrong (#{service.local_auth_mode})") \
    unless service.local_auth_mode == "authenticated"
  puts "  ✓ Test 5: Sdwan::Service local-exposure facet set correctly"

  # Re-expose the SAME existing service by id (update path, not create).
  result4 = ::System::Ai::Skills::ExposeServiceLocalExecutor.new(account: account).execute(
    gated: true,
    service_id: service.id, auth_mode: "scoped", required_permission: "services.smoke.view"
  )
  abort("  ❌ Test 6 FAILED — re-expose returned success: false (#{result4[:error]})") unless result4[:success]
  abort("  ❌ Test 6 FAILED — re-expose should report created: false") \
    unless result4[:data][:created] == false
  abort("  ❌ Test 6 FAILED — auth_mode did not update to scoped") \
    unless service.reload.local_auth_mode == "scoped"
  abort("  ❌ Test 6 FAILED — required_permission did not persist") \
    unless service.local_required_permission == "services.smoke.view"
  puts "  ✓ Test 6: re-exposing an existing service_id updates in place (created: false)"
ensure
  if prior_dynamic_dir.nil?
    ENV.delete("POWERNODE_TRAEFIK_DYNAMIC_DIR")
  else
    ENV["POWERNODE_TRAEFIK_DYNAMIC_DIR"] = prior_dynamic_dir
  end
end

# ── Cleanup ───────────────────────────────────────────────────────────

if ENV["SMOKE_KEEP"] != "1"
  ::Sdwan::Service.where(account: account, slug: "smoke-ingress-svc").destroy_all
  ::Sdwan::PortMapping.where(sdwan_network_id: network.id).destroy_all
  ::Sdwan::VirtualIp.where(network: network).destroy_all
  ::Sdwan::Peer.where(network: network).destroy_all
  network.destroy
  [ hub_instance, backend_instance ].each(&:destroy)
  [ hub_node, backend_node ].each(&:destroy)
  FileUtils.rm_rf(scratch_dir)
  puts ""
  puts "  Cleanup: removed smoke fixtures (set SMOKE_KEEP=1 to preserve)"
end

puts ""
puts "  ✅ All ingress exposure smoke tests passed."
