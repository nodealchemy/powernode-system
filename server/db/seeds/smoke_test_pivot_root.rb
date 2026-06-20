# frozen_string_literal: true

# End-to-end pivot_root smoke test driver.
#
# Exercises the full Powernode-as-OS boot chain on a fresh qemu VM that
# has NO host OS — kernel + initramfs are loaded directly by qemu, the
# agent in the initramfs enrolls via fw-cfg → federation accept →
# node-api enrollment → mTLS cert at /var/lib/powernode/pki, then the
# next reconcile tick pulls system-base + base-os-ubuntu-noble erofs
# blobs, assembles /sysroot as an overlay union, switch_root's into
# the new rootfs where the OS-base module's systemd takes over.
#
# Prerequisites (verified at start; aborts cleanly if missing):
#   1. powernode-system-base + base-os-ubuntu-noble NodeModules exist
#      with current_version_id set (CI must have published their NMVs).
#   2. A Node bound to a template that includes both modules (or with
#      direct NodeModuleAssignment to both). Default: assigns to a Node
#      named "physical-smoke-pivot-root", creating it if missing.
#   3. PVE host with the kernel-initrd staged at
#      /var/lib/vz/template/iso/powernode-{vmlinuz,initramfs.img}.
#      The host hostname is read from the IPNode-PVE provider's
#      connection.config.default_node (typically dna).
#   4. SSH access to operator@<pve-node>.ipnode.net (admin sudo-ssh
#      via the established escalation pattern).
#
# Invoke:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_pivot_root.rb')"
#
# Side effects (logged):
#   - Creates a Federation::Peer in proposed state
#   - Generates a single-use acceptance_token (7d TTL)
#   - Writes fw-cfg payload to /tmp/pn-smoke-fwcfg/ on this host
#   - Streams fw-cfg + qemu-launch script to the PVE node
#   - Launches a transient qemu VM (auto-cleans on exit via -no-reboot)
#   - Captures serial console to /tmp/qemu-smoke.log on the PVE node
#
# Plan reference: see powernode.pivot_root_smoke_proven_2026_05_24
# memory key for the proven boot timeline + the established gotchas.

require "json"
require "fileutils"
require "securerandom"
require "shellwords"

ACCOUNT_NAME       = ENV.fetch("SMOKE_ACCOUNT_NAME", "Powernode Admin")
NODE_NAME          = ENV.fetch("SMOKE_NODE_NAME", "physical-smoke-pivot-root")
PARENT_URL         = ENV.fetch("SMOKE_PARENT_URL", "https://ops.ipnode.us")
PVE_NODE           = ENV.fetch("SMOKE_PVE_NODE", "dna")
FWCFG_DIR_LOCAL    = ENV.fetch("SMOKE_FWCFG_DIR", "/tmp/pn-smoke-fwcfg")
SYSTEM_BASE        = "powernode-system-base"
OS_BASE_UBUNTU     = "base-os-ubuntu-noble"

abort_if = ->(cond, msg) { abort("\n  ⚠  ABORT: #{msg}") if cond }

puts "\n  ===== Pivot-root smoke test driver ====="

# --- Phase A: prerequisite checks ----------------------------------------
account = ::Account.find_by(name: ACCOUNT_NAME)
abort_if.call(account.nil?, "Account #{ACCOUNT_NAME.inspect} not found")
puts "  ✓ Account: #{ACCOUNT_NAME} (#{account.id})"

sb  = ::System::NodeModule.find_by(account: account, name: SYSTEM_BASE)
osb = ::System::NodeModule.find_by(account: account, name: OS_BASE_UBUNTU)
abort_if.call(sb.nil?,  "NodeModule #{SYSTEM_BASE} missing — seed first")
abort_if.call(osb.nil?, "NodeModule #{OS_BASE_UBUNTU} missing — seed first")
puts "  ✓ Modules: #{SYSTEM_BASE} (v#{sb.current_version_number}), #{OS_BASE_UBUNTU} (v#{osb.current_version_number})"

[ sb, osb ].each do |m|
  cv_id = m.try(:current_version_id) || m.try(:current_node_module_version_id)
  abort_if.call(cv_id.blank?, "#{m.name} has no current_version — CI publish must run before smoke")
end

# --- Phase B: ensure Node bound to both modules ---------------------------
node = ::System::Node.find_or_create_by!(account: account, name: NODE_NAME) do |n|
  # Pick a template — physical-smoke if it exists, else any.
  tpl = ::System::NodeTemplate.find_by(account: account, name: "powernode-physical-smoke") ||
        ::System::NodeTemplate.where(account: account).first
  abort_if.call(tpl.nil?, "No NodeTemplate available for #{NODE_NAME}")
  n.node_template = tpl
  n.enabled = true
end
puts "  ✓ Node: #{NODE_NAME} (#{node.id}) bound to template #{node.node_template&.name}"

# Direct module assignment — independent of whatever the template lists,
# guarantees both system-base modules are in the reconciler's input set.
[ sb, osb ].each_with_index do |mod, idx|
  next unless defined?(::System::NodeModuleAssignment)
  ::System::NodeModuleAssignment.find_or_create_by!(node: node, node_module: mod) do |a|
    a.priority = (idx + 1) * 10
    a.enabled = true
  end
end
puts "  ✓ NodeModuleAssignments: #{node.node_module_assignments.count rescue 'n/a'}"

# --- Phase C: Federation::Peer + acceptance token -------------------------
# Stash node_id in metadata so the parent's accept_controller can
# auto-issue node_enrollment.bootstrap_token (per the 2026-05-24 fix).
instance_uuid = ::SecureRandom.uuid
peer = ::System::FederationPeer.create!(
  account: account,
  peer_kind: "platform",
  spawn_mode: "managed_child",
  spawn_role: "parent",
  status: "proposed",
  remote_instance_url: "https://#{NODE_NAME}-#{instance_uuid[0, 8]}.local",
  contract_version_agreed: 1,
  metadata: {
    "smoke_test" => "pivot_root_smoke_#{Time.current.to_i}",
    "node_id" => node.id
  }
)
plaintext_token = peer.generate_acceptance_token!
puts "  ✓ Federation::Peer: #{peer.id}  (token expires #{peer.acceptance_token_expires_at.iso8601})"

# --- Phase D: write fw-cfg payload (operator-only mode 0700/0600) ---------
FileUtils.rm_rf(FWCFG_DIR_LOCAL)
FileUtils.mkdir_p(FWCFG_DIR_LOCAL, mode: 0o700)

{
  "instance_uuid"    => instance_uuid,
  "platform_url"     => PARENT_URL,
  "parent_url"       => PARENT_URL,
  "acceptance_token" => plaintext_token,
  "spawn_mode"       => "managed_child",
  "parent_peer_id"   => peer.id,
  "contract_version" => "v1"
}.each do |key, value|
  path = ::File.join(FWCFG_DIR_LOCAL, key)
  ::File.write(path, value.to_s)
  ::File.chmod(0o600, path)
end
puts "  ✓ fw-cfg payload written to #{FWCFG_DIR_LOCAL} (mode 0600)"

# --- Phase E: pass control to the PVE-side smoke launcher ----------------
# This Ruby driver hands off the heavy lifting (scp + qemu launch +
# serial capture) to a bash script — those operations don't benefit
# from Ruby, and a bash script is easier to maintain + invoke
# independently for debugging.
launcher = ::File.expand_path("../../../scripts/smoke-pivot-root-launch.sh", __dir__)

puts "\n  Next: run the qemu-side launcher on the PVE node:"
puts "    bash #{launcher} \\"
puts "      --pve-node #{PVE_NODE} \\"
puts "      --fwcfg-dir #{FWCFG_DIR_LOCAL} \\"
puts "      --peer-id #{peer.id}"
puts ""
puts "  Driver summary:"
puts ::JSON.pretty_generate({
  account_id: account.id,
  node_id: node.id,
  peer_id: peer.id,
  instance_uuid: instance_uuid,
  parent_url: PARENT_URL,
  pve_node: PVE_NODE,
  fwcfg_dir: FWCFG_DIR_LOCAL,
  expires_at: peer.acceptance_token_expires_at.iso8601
})
