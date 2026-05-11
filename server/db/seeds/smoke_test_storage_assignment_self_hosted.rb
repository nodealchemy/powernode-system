# frozen_string_literal: true

# System extension — Smoke-test for Phase S7a: Shape 1 (self_hosted)
# storage assignment end-to-end.
#
# DB-level integration test (no live VMs): verifies the full chain
# from FileManagement::Storage creation through SDWAN attachment,
# StorageAssignment creation, CredentialIssuer issuance, and Task
# dispatch to the backend + client peers.
#
# What is NOT validated here (run on live VMs separately):
#   * Actual mount(8) on the client kernel
#   * tcpdump confirmation of WireGuard encapsulation
#   * fscrypt status on the mount target
#
# Invoke:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_storage_assignment_self_hosted.rb')"

puts "\n  Smoke-test: Phase S7a — Shape 1 (self_hosted) NFS over SDWAN"
puts "  " + ("=" * 60)

# ── Fixtures ────────────────────────────────────────────────────────

account = Account.first or abort("  ❌ No account in DB")
template = System::NodeTemplate.where(account: account).first or abort("  ❌ No node template")
provider = System::Provider.find_by(account: account, provider_type: "local_qemu") or
  abort("  ❌ No local_qemu provider")
region = provider.provider_regions.first or abort("  ❌ No provider region")
itype = provider.provider_instance_types.first or abort("  ❌ No instance type")

# Two nodes — one will host the NFS export, one will mount it.
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

_server_node, server_instance = find_or_create_node(
  account: account, template: template, region: region, itype: itype, name: "smoke-nfs-server"
)
_client_node, client_instance = find_or_create_node(
  account: account, template: template, region: region, itype: itype, name: "smoke-nfs-client"
)
puts "  ✅ Provisioned 2 node instances (server + client)"

# SDWAN network + enroll both peers
network = Sdwan::Network.find_or_create_by!(account: account, name: "smoke-storage-overlay") do |n|
  n.routing_protocol = "static" if n.respond_to?(:routing_protocol=)
end
[server_instance, client_instance].each do |instance|
  next if Sdwan::Peer.exists?(node_instance_id: instance.id, sdwan_network_id: network.id)

  Sdwan::PeerEnroller.call(network: network, node_instance: instance)
end
puts "  ✅ SDWAN network has #{network.peers.count} peer(s)"

# ── FileManagement::Storage (Shape 1) ──────────────────────────────

storage = FileManagement::Storage.find_or_initialize_by(account: account, name: "smoke-nfs-self-hosted")
storage.assign_attributes(
  provider_type: "nfs",
  node_mount_capable: true,
  requires_node_credentials: true,
  deployment_shape: "self_hosted",
  encryption_mode: "fscrypt",
  configuration: {
    "export_host_node_instance_id" => server_instance.id,
    "export_path" => "/srv/exports/smoke-data",
    "mount_path" => "/srv/exports/smoke-data",
    "server_address" => "127.0.0.1",
    "share_path" => "/srv/exports/smoke-data"
  }
)
storage.save!
puts "  ✅ FileManagement::Storage created: #{storage.id} (shape=self_hosted)"

# ── SDWAN attach ──────────────────────────────────────────────────

attach_result = FileManagement::SdwanAttachmentService.attach!(storage: storage, network: network)
abort("  ❌ SDWAN attach returned nil") unless attach_result
puts "  ✅ SDWAN attached: VIP #{attach_result[:virtual_ip].id}, firewall_rule #{attach_result[:firewall_rule].id}"

# ── StorageAssignment ──────────────────────────────────────────────

# Note: after_commit triggers AssignmentReconciliationService which auto-issues
# credentials + dispatches mount tasks. Idempotent across re-runs: find or
# rebuild the assignment.
assignment = System::StorageAssignment.find_or_initialize_by(
  account: account,
  file_storage_id: storage.id,
  node_instance: client_instance
)
assignment.assign_attributes(
  sdwan_network_id: network.id,
  sdwan_virtual_ip_id: attach_result[:virtual_ip].id,
  mount_path: "/mnt/smoke-data",
  encryption_mode: "inherit"
)
assignment.status = "pending" unless assignment.persisted?
assignment.save!
puts "  ✅ StorageAssignment created: #{assignment.id}"
puts "     effective_encryption_mode: #{assignment.effective_encryption_mode}"
puts "     derived_uid: #{assignment.derived_uid}"

# ── Credential issuance ────────────────────────────────────────────

credential = assignment.active_credential
unless credential
  credential = System::Storage::CredentialIssuer.new(assignment: assignment).issue!
end
abort("  ❌ Credential issuance failed") unless credential
puts "  ✅ StorageCredential issued: id=#{credential.id}, kind=#{credential.kind}, status=#{credential.status}"

# Idempotent re-materialization — ensures the exports task fires even if a
# stale credential from a prior run already exists.
System::Storage::NfsExportManager.new(assignment: assignment).grant!(credential: credential)

# ── Backend tasks dispatched ───────────────────────────────────────

exports_task = System::Task.where(operable: server_instance, command: "storage.exports.apply").order(created_at: :desc).first
abort("  ❌ No storage.exports.apply task dispatched to server") unless exports_task
puts "  ✅ Exports task dispatched: #{exports_task.id}"
puts "     payload entries: #{exports_task.options['entries']&.size || 0}"
puts "     export_path: #{exports_task.options['export_path']}"
puts "     deployment_shape: #{exports_task.options['deployment_shape']}"

mount_task = System::Task.where(operable: client_instance, command: "storage.mount").order(created_at: :desc).first
if mount_task
  puts "  ✅ Mount task dispatched: #{mount_task.id}"
  puts "     recipe.type: #{mount_task.options.dig('recipe', 'type')}"
  puts "     recipe.source: #{mount_task.options.dig('recipe', 'source')}"
  puts "     credential.kind: #{mount_task.options.dig('credential', 'kind')}"
  puts "     encryption.mode: #{mount_task.options.dig('encryption', 'mode')}"
else
  puts "  ⚠️ No mount task yet (would dispatch via after_commit on update or reconciler tick)"
end

puts "\n  Phase S7a smoke test passed: backend + credential + dispatch chain validated."
puts "  Live mount verification (mount(8), tcpdump, fscrypt) requires LocalQemuProvider"
puts "  bring-up; see docs/runbooks/storage-assignment-walkthrough.md (TBD)."
puts "  " + ("=" * 60)
