# frozen_string_literal: true

# System extension — Smoke-test for Phase N0 (membership credentials).
#
# DB-level integration test: issues, verifies, refreshes, and revokes
# membership credentials end-to-end against the live database. Does NOT
# spawn VMs — companion VM-mesh smoke (smoke_test_membership_credentials_vm.rb)
# covers the agent ↔ kernel boundary.
#
# Asserts the contract the agent's mc_verifier.go relies on:
#   1. ensure_fresh! issues an active MC with a wire envelope
#   2. The Ed25519 signature verifies against the constellation public key
#   3. Repeated ensure_fresh! within the refresh window returns the SAME MC
#   4. Revocation marks the MC revoked and a subsequent ensure_fresh! mints a new one
#   5. The wire envelope contains every field the agent's MCWire struct expects
#
# Invoke:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_membership_credentials.rb')"

require "openssl"
require "base64"
require "json"

puts "\n  Smoke-test: Phase N0 — Membership Credentials"
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

node = System::Node.find_or_create_by!(account: account, name: "smoke-mc-host") do |n|
  n.node_template = template
end

instance = System::NodeInstance.find_or_initialize_by(node: node, name: "smoke-mc-host-instance")
instance.assign_attributes(
  variety: "cloud",
  provider_region: region,
  provider_instance_type: itype,
  status: "running"
)
instance.save!

# Fresh network so we don't collide with other smoke runs.
network = ::Sdwan::Network.find_or_create_by!(account: account, name: "smoke-mc-network") do |n|
  n.cidr_64 = "fd00:dead:beef:#{rand(0x1000..0xffff).to_s(16)}::/64"
  n.routing_protocol = "static"
  n.settings = { "topology_strategy" => "hub_and_spoke" }
end

# Reset peer to a known shape (deletes any prior MCs to test fresh issuance).
::Sdwan::MembershipCredential.where(sdwan_network_id: network.id).destroy_all
::Sdwan::Peer.where(network: network, node_instance: instance).destroy_all

peer = ::Sdwan::PeerEnroller.call(network: network, node_instance: instance)

puts "  Account:  #{account.id[0..7]}…"
puts "  Network:  #{network.name} (#{network.id[0..7]}…)"
puts "  Peer:     #{peer.id[0..7]}…  addr=#{peer.assigned_address}"
puts ""

# ── Test 1: ensure_fresh! issues an MC ────────────────────────────────

mc = ::Sdwan::MembershipCredentialSigner.ensure_fresh!(peer: peer)
abort("  ❌ Test 1 FAILED — ensure_fresh! returned nil") if mc.nil?
abort("  ❌ Test 1 FAILED — MC not active (status=#{mc.status})") unless mc.status == "active"
puts "  ✓ Test 1: MC issued (revision=#{mc.revision}, exp=#{mc.not_after.iso8601})"

# ── Test 2: wire envelope has every required field ────────────────────

wire = mc.to_wire
%w[envelope signature constellation_handle revision not_before not_after refresh_after].each do |k|
  abort("  ❌ Test 2 FAILED — wire missing :#{k}") if wire[k.to_sym].nil? && wire[k].nil?
end
envelope = JSON.parse(wire[:envelope] || wire["envelope"])
%w[iss sub aud iat nbf exp rev wg_pubkey addr_v6 endpoints].each do |k|
  abort("  ❌ Test 2 FAILED — envelope missing :#{k}") unless envelope.key?(k)
end
puts "  ✓ Test 2: wire envelope schema matches MCWire (#{envelope.keys.length} fields)"

# ── Test 3: Ed25519 signature verifies ────────────────────────────────

sig_b64 = wire[:signature] || wire["signature"]
handle  = wire[:constellation_handle] || wire["constellation_handle"]
ck      = ::Sdwan::ConstellationSigningKey.find_by(account: account, handle: handle)
abort("  ❌ Test 3 FAILED — no ConstellationSigningKey for handle=#{handle}") unless ck

pub_raw = Base64.decode64(ck.public_key_b64)
pub     = OpenSSL::PKey.new_raw_public_key("ED25519", pub_raw)
verified = pub.verify(nil, Base64.decode64(sig_b64), wire[:envelope] || wire["envelope"])
abort("  ❌ Test 3 FAILED — Ed25519 verify returned false (signature does not match)") unless verified
puts "  ✓ Test 3: Ed25519 signature verifies against constellation pubkey"

# ── Test 4: ensure_fresh! within refresh window is idempotent ─────────

mc2 = ::Sdwan::MembershipCredentialSigner.ensure_fresh!(peer: peer.reload)
abort("  ❌ Test 4 FAILED — repeat issuance returned new row id") unless mc2.id == mc.id
abort("  ❌ Test 4 FAILED — repeat issuance bumped revision") unless mc2.revision == mc.revision
puts "  ✓ Test 4: ensure_fresh! within refresh window returns same MC (idempotent)"

# ── Test 5: explicit issue! supersedes previous active MC ─────────────

# Direct issue! bypasses the refresh-window check in ensure_fresh!.
# Tests that the signer's supersede-then-issue logic produces a fresh
# row with a bumped revision (and the previous one moves out of the
# unique active partial index).
mc3 = ::Sdwan::MembershipCredentialSigner.issue!(peer: peer.reload)
abort("  ❌ Test 5 FAILED — direct issue! returned same row id") if mc3.id == mc.id
abort("  ❌ Test 5 FAILED — new MC revision did not bump (#{mc3.revision} <= #{mc.revision})") unless mc3.revision > mc.revision
abort("  ❌ Test 5 FAILED — old MC was not superseded") if ::Sdwan::MembershipCredential.find(mc.id).status == "active"
puts "  ✓ Test 5: explicit issue! supersedes previous and bumps revision (#{mc.revision} → #{mc3.revision})"

# ── Test 6: revocation ────────────────────────────────────────────────

::Sdwan::MembershipCredentialSigner.revoke_for!(peer: peer.reload)
revoked_count = ::Sdwan::MembershipCredential.where(sdwan_network_id: network.id, sdwan_peer_id: peer.id, status: "revoked").count
abort("  ❌ Test 6 FAILED — revocation did not mark any MCs revoked") if revoked_count.zero?
active_count = ::Sdwan::MembershipCredential.where(sdwan_network_id: network.id, sdwan_peer_id: peer.id, status: "active").count
abort("  ❌ Test 6 FAILED — revocation left #{active_count} active MCs") unless active_count.zero?
puts "  ✓ Test 6: revoke_for! marks MCs revoked (#{revoked_count} revoked, #{active_count} active)"

# ── Test 7: post-revocation ensure_fresh! mints a new MC ──────────────

mc4 = ::Sdwan::MembershipCredentialSigner.ensure_fresh!(peer: peer.reload)
abort("  ❌ Test 7 FAILED — post-revocation issuance returned nil") if mc4.nil?
abort("  ❌ Test 7 FAILED — post-revocation MC not active (status=#{mc4.status})") unless mc4.status == "active"
puts "  ✓ Test 7: post-revocation ensure_fresh! mints a fresh active MC"

# ── Cleanup ───────────────────────────────────────────────────────────

if ENV["SMOKE_KEEP"] != "1"
  ::Sdwan::MembershipCredential.where(sdwan_network_id: network.id).destroy_all
  ::Sdwan::Peer.where(network: network).destroy_all
  network.destroy
  instance.destroy
  node.destroy
  puts ""
  puts "  Cleanup: removed smoke fixtures (set SMOKE_KEEP=1 to preserve)"
end

puts ""
puts "  ✅ All N0 smoke tests passed."
