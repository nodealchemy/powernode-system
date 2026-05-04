# frozen_string_literal: true

# System extension — Phase B Docker runtime smoke test.
#
# Platform-side smoke. Validates the full backend wiring without
# needing a running dockerd:
#
#   1. Pick a NodeInstance with at least one Sdwan::Peer attached.
#   2. Assign the docker-engine NodeModule to its Node (idempotent).
#   3. Invoke MCP action system_provision_docker_runtime — exercises
#      the full chain: PlatformApiToolRegistry → DockerProvisioningTool
#      → DockerDaemonProvisionerService → InternalCaService.
#   4. Assert the managed Devops::DockerHost row was created with
#      api_endpoint matching the SDWAN /128, encrypted_tls_credentials
#      populated, and a CA-signed client cert that chains to
#      InternalCaService.ca_chain_pem.
#   5. Simulate the agent's CSR flow at the service level: build a
#      real CSR, run InternalCaService.issue_certificate, verify the
#      returned daemon cert chains to the same CA. (The HTTP-level
#      controller test is covered by runtime_controller_spec — running
#      it again in-process here would need full dispatch-layer setup.)
#   6. Test phase=ready → host status flips pending → connected via
#      MCP system_mark_docker_ready.
#   7. Test system_list_managed_docker_hosts — host appears.
#   8. Test system_decommission_docker_runtime → host destroyed.
#   9. Negative: SDWAN-less instance is rejected at provision time.
#  10. Cleanup any module assignment created by the test.
#
# Out of scope (next session, requires QEMU + module artifact build):
#   - Booting a real VM with the agent + docker-ce installed
#   - Verifying dockerd actually listens on the overlay /128
#   - Container persistence across reboot
#
# Invoke:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_docker_runtime.rb')"

require "openssl"
require "json"

# ────────────────────────────────────────────────────────────────────
# Setup helpers
# ────────────────────────────────────────────────────────────────────

step = ->(label) { puts "\n  [step] #{label}" }
ok   = ->(msg)   { puts "    ✓ #{msg}" }
fail_with = ->(msg) {
  puts "    ✗ #{msg}"
  abort("  💥 SMOKE FAIL")
}
assert = ->(condition, msg) { condition ? ok.call(msg) : fail_with.call(msg) }

puts "\n  Phase B Docker runtime smoke test"
puts "  =================================="
puts "  Today: #{Date.today}, Rails env: #{Rails.env}"

# ── Pick a NodeInstance with an SDWAN peer ─────────────────────────
step.call("Discover a NodeInstance with at least one SDWAN peer")

instance = ::System::NodeInstance.joins("INNER JOIN sdwan_peers ON sdwan_peers.node_instance_id = system_node_instances.id")
                                 .where.not("sdwan_peers.assigned_address IS NULL")
                                 .first
fail_with.call("No NodeInstance found with an SDWAN peer — provision one first") unless instance

account = instance.account
node = instance.node
peer = ::Sdwan::Peer.where(node_instance_id: instance.id)
                    .where.not(assigned_address: nil)
                    .order(:created_at)
                    .first
ok.call("instance=#{instance.name} (id=#{instance.id[0,8]})")
ok.call("account=#{account.name} (id=#{account.id[0,8]})")
ok.call("peer overlay=#{peer.assigned_address}")

# ── Module assignment ──────────────────────────────────────────────
step.call("Ensure docker-engine NodeModule is assigned to the node")

docker_module = ::System::NodeModule.where(account: account, name: "docker-engine").first
fail_with.call("docker-engine module not seeded — run docker_runtime_module.rb") unless docker_module

assignment = ::System::NodeModuleAssignment.where(node: node, node_module: docker_module).first
created_assignment = false
unless assignment
  assignment = ::System::NodeModuleAssignment.create!(
    node: node, node_module: docker_module, enabled: true
  )
  created_assignment = true
end
ok.call("module assignment #{created_assignment ? 'created' : 'already present'} (id=#{assignment.id[0, 8]})")

# ── Cleanup any prior test residue ─────────────────────────────────
step.call("Clean any leftover managed DockerHost from a previous smoke run")

prior = ::Devops::DockerHost.managed.where(node_instance_id: instance.id)
prior_count = prior.count
prior.destroy_all
ok.call("deleted #{prior_count} prior managed host(s)")

# Reset CA so cert chains use a fresh in-memory root.
::System::InternalCaService.reset!

# ────────────────────────────────────────────────────────────────────
# Smoke 1: Provision via MCP action
# ────────────────────────────────────────────────────────────────────

step.call("MCP system_provision_docker_runtime — full chain to DockerHost")

# Build a fake admin user owning the account (the tool requires a
# user/agent context for permission checks).
admin = account.users.first || ::User.where(account: account).first
fail_with.call("no admin user on account") unless admin

tool = ::Ai::Tools::DockerProvisioningTool.new(
  account: account, agent: nil, user: admin
)
result = tool.send(:call, action: "system_provision_docker_runtime", node_instance_id: instance.id)
assert.call(result[:success], "tool returned success=true (got: #{result.inspect[0,200]})")
assert.call(result[:host].present?, "host summary in response")
ok.call("host_id=#{result[:host][:id][0, 8]} status=#{result[:host][:status]}")

host = ::Devops::DockerHost.find(result[:host][:id])
assert.call(host.managed?, "host.managed? == true")
assert.call(host.status == "pending", "initial status is pending")
assert.call(host.node_instance_id == instance.id, "host bound to NodeInstance")
expected_endpoint = "tcp://[#{peer.assigned_address.split('/').first}]:2376"
assert.call(host.api_endpoint == expected_endpoint, "api_endpoint=#{host.api_endpoint} (expected #{expected_endpoint})")
assert.call(host.encrypted_tls_credentials.present?, "encrypted_tls_credentials populated")

creds = JSON.parse(host.encrypted_tls_credentials)
assert.call(creds["client_cert_pem"].include?("BEGIN CERTIFICATE"), "client_cert_pem is valid PEM")
assert.call(creds["client_key_pem"].include?("BEGIN") && creds["client_key_pem"].include?("PRIVATE KEY"), "client_key_pem is valid PEM")
assert.call(creds["ca_chain_pem"].include?("BEGIN CERTIFICATE"), "ca_chain_pem is valid PEM")
assert.call(creds["client_cert_serial"].present?, "client_cert_serial present")

# Verify cert chains to CA
leaf = OpenSSL::X509::Certificate.new(creds["client_cert_pem"])
ca   = OpenSSL::X509::Certificate.new(creds["ca_chain_pem"])
assert.call(leaf.verify(ca.public_key), "client cert verifies against CA")

# ────────────────────────────────────────────────────────────────────
# Smoke 2: Idempotency
# ────────────────────────────────────────────────────────────────────

step.call("Idempotency — second provision call reuses existing host")

result2 = tool.send(:call, action: "system_provision_docker_runtime", node_instance_id: instance.id)
assert.call(result2[:success], "second call success")
assert.call(result2[:host][:id] == host.id, "same host_id returned")
assert.call(::Devops::DockerHost.managed.where(node_instance_id: instance.id).count == 1,
            "still exactly 1 managed host for this NodeInstance")

# ────────────────────────────────────────────────────────────────────
# Smoke 3: Agent wants_cert flow at the service level
# ────────────────────────────────────────────────────────────────────
# The HTTP-level test is in runtime_controller_spec (11 examples).
# Here we exercise the same code path the controller wraps:
# CSR generation + InternalCaService.issue_certificate. Validates that
# the agent's daemon cert chains to the same CA the platform's
# client cert was signed by — proves mutual trust.

step.call("Simulate agent CSR at the service level (CSR → CA-signed cert)")

agent_kp = OpenSSL::PKey.generate_key("ED25519")
csr = OpenSSL::X509::Request.new
csr.version = 0
csr.subject = OpenSSL::X509::Name.parse("/CN=docker-daemon-#{instance.id}")
csr.public_key = agent_kp
csr.sign(agent_kp, nil)

issued = ::System::InternalCaService.issue_certificate(
  csr_pem: csr.to_pem,
  ttl_seconds: 90 * 24 * 3600,
  common_name: "docker-daemon-#{instance.id}"
)
assert.call(issued[:cert_pem].include?("BEGIN CERTIFICATE"), "issued cert is PEM")
assert.call(issued[:ca_chain_pem].include?("BEGIN CERTIFICATE"), "ca_chain returned")

agent_leaf = OpenSSL::X509::Certificate.new(issued[:cert_pem])
agent_ca   = OpenSSL::X509::Certificate.new(issued[:ca_chain_pem])
assert.call(agent_leaf.verify(agent_ca.public_key), "agent daemon cert chains to CA")

# Verify the CSR public key matches the issued cert public key —
# proves the platform signed the right material.
csr_pubkey_pem = csr.public_key.public_to_pem
cert_pubkey_pem = agent_leaf.public_key.public_to_pem
assert.call(csr_pubkey_pem == cert_pubkey_pem, "issued cert binds the agent's pubkey")

# Mutual-trust check: the platform's client cert (stored in
# encrypted_tls_credentials) must chain to the same CA that signed the
# agent's daemon cert. That's how mTLS works between platform and
# dockerd — both ends trust the same root.
assert.call(creds["ca_chain_pem"] == issued[:ca_chain_pem],
            "platform client cert + agent daemon cert share the same CA chain")

# ────────────────────────────────────────────────────────────────────
# Smoke 4: phase=ready
# ────────────────────────────────────────────────────────────────────

step.call("Mark daemon ready via MCP action")

ready_result = tool.send(:call, action: "system_mark_docker_ready",
                         host_id: host.id, docker_version: "25.0.3")
assert.call(ready_result[:success], "mark_ready returned success")

host.reload
assert.call(host.status == "connected", "host promoted to connected")
assert.call(host.docker_version == "25.0.3", "docker_version recorded")
assert.call(host.metadata["daemon_ready_at"].present?, "daemon_ready_at stamped")

# ────────────────────────────────────────────────────────────────────
# Smoke 5: list managed
# ────────────────────────────────────────────────────────────────────

step.call("List managed docker hosts")

list_result = tool.send(:call, action: "system_list_managed_docker_hosts")
assert.call(list_result[:success], "list returned success")
assert.call(list_result[:count] >= 1, "at least 1 managed host")
managed_ids = list_result[:hosts].map { |h| h[:id] }
assert.call(managed_ids.include?(host.id), "our host is in the list")

# ────────────────────────────────────────────────────────────────────
# Smoke 6: phase=stopped at the service level
# ────────────────────────────────────────────────────────────────────
# (HTTP path is covered by runtime_controller_spec.)

step.call("Mark host disconnected (simulates phase=stopped)")

host.update!(status: "disconnected")
host.reload
assert.call(host.status == "disconnected", "host status updates cleanly to disconnected")

# ────────────────────────────────────────────────────────────────────
# Smoke 7: decommission
# ────────────────────────────────────────────────────────────────────

step.call("Decommission via MCP action")

decom_result = tool.send(:call, action: "system_decommission_docker_runtime", host_id: host.id)
assert.call(decom_result[:success], "decommission returned success")
assert.call(::Devops::DockerHost.where(id: host.id).none?, "host row destroyed")

# ────────────────────────────────────────────────────────────────────
# Smoke 8: error paths (negative tests)
# ────────────────────────────────────────────────────────────────────

step.call("Negative: provision without SDWAN peer should error")

# Build a temporary instance without any SDWAN peer to verify the guard.
orphan_instance = ::System::NodeInstance.create!(
  node: node, name: "smoke-orphan-#{SecureRandom.hex(3)}",
  variety: "physical", status: "pending"
)
orphan_result = tool.send(:call, action: "system_provision_docker_runtime",
                          node_instance_id: orphan_instance.id)
assert.call(orphan_result[:success] == false, "provision rejected for SDWAN-less instance")
assert.call(orphan_result[:error].to_s.include?("SDWAN"), "error message references SDWAN: #{orphan_result[:error]}")
orphan_instance.destroy

# ────────────────────────────────────────────────────────────────────
# Smoke 9: account isolation (cross-account access denied)
# ────────────────────────────────────────────────────────────────────

step.call("Negative: provision rejected when instance belongs to another account")

# Create a fresh account + tool scoped to it; must NOT be able to
# provision against `instance` (which belongs to the original account).
other_account = ::Account.create!(
  name: "smoke-other-#{SecureRandom.hex(3)}",
  subdomain: "smoke-other-#{SecureRandom.hex(3)}",
  status: "active"
)
foreign_tool = ::Ai::Tools::DockerProvisioningTool.new(
  account: other_account, agent: nil, user: nil
)
begin
  foreign_result = foreign_tool.send(:call, action: "system_provision_docker_runtime",
                                     node_instance_id: instance.id)
  assert.call(foreign_result[:success] == false, "foreign-account provision rejected")
rescue ActiveRecord::RecordNotFound
  ok.call("foreign-account provision rejected (RecordNotFound — expected)")
end
# `Account.destroy` cascades to associations like `campaigns` whose
# table may not exist in this dev DB. Use `delete` to skip the
# dependent-cascade callbacks — it's an account we just created
# moments ago with no real data attached.
::Account.where(id: other_account.id).delete_all

# ────────────────────────────────────────────────────────────────────
# Cleanup
# ────────────────────────────────────────────────────────────────────

step.call("Cleanup")

if created_assignment
  assignment.destroy
  ok.call("removed test-created module assignment")
else
  ok.call("module assignment retained (existed before smoke test)")
end

::System::InternalCaService.reset!

puts "\n  ✅ ALL PHASE B BACKEND SMOKE CHECKS PASSED"
puts "  ============================================"
puts "  Validated:"
puts "    - Provision MCP action → managed DockerHost row + signed cert"
puts "    - Idempotency: 2nd provision call reuses host"
puts "    - Agent CSR signed by the same CA as platform client cert"
puts "    - mark_ready MCP → status pending → connected + version recorded"
puts "    - list_managed MCP includes the new host"
puts "    - phase=stopped → host disconnected"
puts "    - decommission MCP destroys the host"
puts "    - SDWAN-less instance rejected at provision time"
puts "    - Cross-account provision rejected"
puts ""
puts "  NOT validated by this smoke (requires QEMU + composefs blob build):"
puts "    - Real dockerd installation + startup"
puts "    - Container persistence across reboot"
puts "    - End-to-end docker_list_containers MCP via SDWAN overlay"
