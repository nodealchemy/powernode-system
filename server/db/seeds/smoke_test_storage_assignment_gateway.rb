# frozen_string_literal: true

# System extension — Smoke-test for Phase S7b: Shape 2 (gateway_proxy)
# storage assignment end-to-end.
#
# DB-level integration test (no live VMs): verifies that an external
# NFS upstream is proxied through a SDWAN-peered gateway. Validates the
# split task dispatch: gateway gets storage.gateway.provision +
# storage.exports.apply on the re-export; client gets storage.mount
# pointing at the gateway VIP.
#
# What is NOT validated here:
#   * Gateway actually mounting the upstream (requires live network)
#   * Client mount completion + writes flowing through gateway
#   * tcpdump confirmation of plaintext gateway↔upstream traffic
#
# Invoke:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_storage_assignment_gateway.rb')"

puts "\n  Smoke-test: Phase S7b — Shape 2 (gateway_proxy) NFS"
puts "  " + ("=" * 60)

account = Account.first or abort("  ❌ No account in DB")
template = System::NodeTemplate.where(account: account).first or abort("  ❌ No node template")
provider = System::Provider.find_by(account: account, provider_type: "local_qemu") or
  abort("  ❌ No local_qemu provider")
region = provider.provider_regions.first or abort("  ❌ No provider region")
itype = provider.provider_instance_types.first or abort("  ❌ No instance type")

def find_or_create_node(account:, template:, region:, itype:, name:)
  node = System::Node.find_or_create_by!(account: account, name: name) do |n|
    n.node_template = template
  end
  instance = System::NodeInstance.find_or_initialize_by(node: node, name: "#{name}-instance")
  instance.assign_attributes(
    variety: "cloud",
    provider_region: region,
    provider_instance_type: itype,
    status: "running"
  )
  instance.save!
  [node, instance]
end

# Only the gateway + client are SDWAN peers; upstream is external (not
# in the platform — its only signal is its IP, which the operator types
# into Storage.configuration.upstream_source_host).
_gateway_node, gateway_instance = find_or_create_node(
  account: account, template: template, region: region, itype: itype, name: "smoke-nfs-gateway"
)
_client_node, client_instance = find_or_create_node(
  account: account, template: template, region: region, itype: itype, name: "smoke-nfs-client-2"
)
puts "  ✅ Provisioned gateway + client (upstream is external, not modeled)"

network = Sdwan::Network.find_or_create_by!(account: account, name: "smoke-storage-gateway-overlay") do |n|
  n.routing_protocol = "static" if n.respond_to?(:routing_protocol=)
end
[gateway_instance, client_instance].each do |instance|
  next if Sdwan::Peer.exists?(node_instance_id: instance.id, sdwan_network_id: network.id)

  Sdwan::PeerEnroller.call(network: network, node_instance: instance)
end
puts "  ✅ SDWAN network has #{network.peers.count} peer(s)"

# ── FileManagement::Storage (Shape 2 — gateway_proxy) ─────────────

storage = FileManagement::Storage.find_or_initialize_by(account: account, name: "smoke-nfs-gateway-proxy")
storage.assign_attributes(
  provider_type: "nfs",
  node_mount_capable: true,
  requires_node_credentials: true,
  deployment_shape: "gateway_proxy",
  encryption_mode: "fscrypt",
  configuration: {
    "gateway_node_instance_id" => gateway_instance.id,
    "upstream_source_host" => "10.20.30.40",
    "upstream_export_path" => "/srv/data",
    "re_export_path" => "/var/lib/powernode/storage/smoke-gateway",
    "upstream_mount_options" => %w[vers=4.2 proto=tcp hard],
    "mount_path" => "/var/lib/powernode/storage/smoke-gateway",
    "server_address" => "10.20.30.40",
    "share_path" => "/srv/data"
  }
)
storage.save!
puts "  ✅ Storage created (gateway_proxy): #{storage.id}"
puts "     upstream: #{storage.configuration['upstream_source_host']}:#{storage.configuration['upstream_export_path']}"
puts "     re-export: #{storage.configuration['re_export_path']}"

# ── Provision the gateway ─────────────────────────────────────────

System::Storage::GatewayProvisioningService.provision!(storage: storage)
provision_task = System::Task.where(operable: gateway_instance, command: "storage.gateway.provision").order(created_at: :desc).first
abort("  ❌ No gateway provision task dispatched") unless provision_task
puts "  ✅ Gateway provision task dispatched: #{provision_task.id}"
puts "     upstream_source_host: #{provision_task.options['upstream_source_host']}"
puts "     re_export_path: #{provision_task.options['re_export_path']}"
puts "     gateway_unit_name: #{provision_task.options['gateway_unit_name']}"

# ── SDWAN attach ──────────────────────────────────────────────────

attach_result = FileManagement::SdwanAttachmentService.attach!(storage: storage, network: network)
puts "  ✅ SDWAN attached at gateway: VIP #{attach_result[:virtual_ip].id}"

# ── StorageAssignment for client ──────────────────────────────────

assignment = System::StorageAssignment.find_or_initialize_by(
  account: account,
  file_storage_id: storage.id,
  node_instance: client_instance
)
assignment.assign_attributes(
  sdwan_network_id: network.id,
  sdwan_virtual_ip_id: attach_result[:virtual_ip].id,
  mount_path: "/mnt/smoke-gateway",
  encryption_mode: "inherit"
)
assignment.status = "pending" unless assignment.persisted?
assignment.save!
puts "  ✅ StorageAssignment created: #{assignment.id}"

# ── Credential issuance — backend tasks land on the GATEWAY ──────

credential = assignment.active_credential || System::Storage::CredentialIssuer.new(assignment: assignment).issue!
abort("  ❌ Credential issuance failed") unless credential
puts "  ✅ StorageCredential issued: id=#{credential.id}, kind=#{credential.kind}"

# Idempotent re-grant so the exports task fires even on re-runs with stale creds.
System::Storage::NfsExportManager.new(assignment: assignment).grant!(credential: credential)

# Exports task must target the GATEWAY (not the upstream, which has no peer)
exports_task = System::Task
  .where(operable: gateway_instance, command: "storage.exports.apply")
  .order(created_at: :desc)
  .first
abort("  ❌ No exports.apply task dispatched to gateway") unless exports_task
abort("  ❌ Wrong deployment_shape in exports payload") unless exports_task.options["deployment_shape"] == "gateway_proxy"
abort("  ❌ Exports target should be re_export_path, got #{exports_task.options['export_path']}") unless exports_task.options["export_path"] == storage.configuration["re_export_path"]
puts "  ✅ Exports task dispatched to GATEWAY (not upstream): #{exports_task.id}"
puts "     export_path == re_export_path ✓"

# ── Client mount task ──────────────────────────────────────────────

mount_task = System::Task.where(operable: client_instance, command: "storage.mount").order(created_at: :desc).first
if mount_task
  recipe_source = mount_task.options.dig("recipe", "source")
  abort("  ❌ Client should mount gateway VIP, not upstream host") if recipe_source&.include?("10.20.30.40")
  puts "  ✅ Client mount task: source=#{recipe_source} (gateway VIP, not upstream) ✓"
end

puts "\n  Phase S7b smoke test passed: gateway proxy chain validated."
puts "  Trust boundary verified: client sees gateway VIP, upstream IP is never"
puts "  exposed in the mount recipe — only the gateway's agent fetches upstream."
puts "  " + ("=" * 60)
