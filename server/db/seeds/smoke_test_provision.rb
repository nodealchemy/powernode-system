# frozen_string_literal: true

# System extension — Smoke-test provisioning driver.
#
# Exercises the LocalQemuProvider end-to-end against the node-module
# catalog (see node_module_catalog.rb).
# Two modes:
#   POWERNODE_LIBVIRT_MODE=local   → RecorderRunner (default in dev) — validates
#                                    dispatch chain logically without VM startup
#   POWERNODE_LIBVIRT_MODE=real    → LibvirtRunner (real virsh) — actually boots
#                                    a domain. With qemu:///session no group
#                                    membership needed; with no /dev/kvm uses TCG.
#
# Outputs:
#   - prints the assembled domain XML (truncated)
#   - prints the bootstrap token + fw-cfg entries
#   - reports the recorded virsh calls (or actual results if mode=real)
#
# Invoke:
#   cd server && POWERNODE_LIBVIRT_MODE=local bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_provision.rb')"
#
# Reference: Golden Eclipse plan M4 verification plan.

puts "\n  Smoke-test provisioning…"
puts "  POWERNODE_LIBVIRT_MODE=#{ENV.fetch('POWERNODE_LIBVIRT_MODE', '(default — local in dev)')}"
puts "  POWERNODE_LIBVIRT_URI=#{ENV.fetch('POWERNODE_LIBVIRT_URI', 'qemu:///session (default)')}"

account  = Account.first or abort("  ❌ No account")
template = System::NodeTemplate.find_by(account: account, name: ENV.fetch('SMOKE_TEMPLATE', 'base'))
abort("  ❌ Template not found — run node_module_catalog.rb first") unless template

provider = System::Provider.find_by(account: account, provider_type: "local_qemu") or abort("  ❌ No local_qemu provider — re-run node_module_catalog")
region   = provider.provider_regions.find_by(region_code: "local") or abort("  ❌ No local region")
itype    = provider.provider_instance_types.find_by(instance_type_code: "qemu.small") or abort("  ❌ No qemu.small itype — re-run node_module_catalog")

puts "  Template: #{template.name} (#{template.template_modules.count} modules)"
puts "  Provider: #{provider.name} → #{region.region_code} → #{itype.name}"
puts ""

# ── Create or reuse a Node + Instance pair ────────────────────────────────

node = System::Node.find_or_create_by!(account: account, name: ENV.fetch('SMOKE_NODE_NAME', 'smoke-test-1')) do |n|
  n.node_template = template
  n.description   = "Smoke-test node — auto-created by smoke_test_provision.rb"
end

# Inject the operator's SSH pubkey into the Node's authorized_keys list so the
# on-node agent can fetch it via /api/v1/system/node_api/config/authorized_keys
# and write it to /root/.ssh/authorized_keys for SSH access.
operator_pubkey = ENV["POWERNODE_OPERATOR_SSH_PUBKEY"].presence
if operator_pubkey.nil?
  candidate = ["#{Dir.home}/.ssh/id_ed25519.pub",
               "#{Dir.home}/.ssh/id_rsa.pub",
               "#{Dir.home}/.ssh/id_ecdsa.pub"].find { |p| File.exist?(p) }
  operator_pubkey = File.read(candidate).strip if candidate
  puts "  SSH key:  read from #{candidate}" if candidate
end
if operator_pubkey
  current_keys = Array(node.config.is_a?(Hash) && node.config["authorized_keys"])
  unless current_keys.include?(operator_pubkey)
    new_config = (node.config || {}).merge("authorized_keys" => (current_keys + [operator_pubkey]).uniq)
    node.update!(config: new_config)
    puts "  SSH key:  injected into node.config['authorized_keys'] (now #{node.authorized_keys.length} key(s))"
  else
    puts "  SSH key:  already present on node (#{node.authorized_keys.length} key(s))"
  end
else
  puts "  SSH key:  ⚠️  no host SSH pubkey found — VM will boot without authorized_keys"
end

instance = System::NodeInstance.find_or_initialize_by(node: node, name: ENV.fetch('SMOKE_INSTANCE_NAME', "#{node.name}-instance"))
instance.assign_attributes(
  node:                   node,
  variety:                "cloud", # local_qemu treats VMs as cloud variety
  provider_region:        region,
  provider_instance_type: itype,
  status:                 "pending"
)
instance.save!

puts "  Node:     #{node.name} (id=#{node.id[0..7]}…)"
puts "  Instance: #{instance.name} (id=#{instance.id[0..7]}… status=#{instance.status})"
puts ""

# ── Drive the provider directly (skips ProvisioningService orchestration) ─

connection = provider.provider_connections.find_by(name: "qemu-conn") or abort("  ❌ No qemu-conn — re-run node_module_catalog")
adapter = System::Providers::Registry.for(connection, region: region)
puts "  Adapter:  #{adapter.class.name} (provider_type=#{adapter.provider_type})"
puts "  Runner:   #{System::Providers::LocalQemuProvider.runner.class.name}"
puts ""

result = adapter.create_instance(
  instance:     instance,
  name:         "powernode-smoke-#{instance.id[0..7]}",
  arch:         "amd64",
  memory_mb:    1024,
  vcpus:        1,
  options:      {}
)

puts "  ── create_instance result ─────────────────────────────────────"
result.each { |k, v| puts "    #{k.to_s.ljust(20)} #{v.is_a?(String) && v.length > 100 ? v[0..100] + '…' : v.inspect}" }
puts ""

# ── For RecorderRunner: dump recorded calls ────────────────────────────────

if System::Providers::LocalQemuProvider.runner.respond_to?(:recorded_calls)
  calls = System::Providers::LocalQemuProvider.runner.recorded_calls
  puts "  ── Recorded virsh calls (#{calls.length}) ──"
  calls.each_with_index do |c, i|
    puts "    [#{i}] #{c[:method]} args=#{c[:args].inspect.first(120)}"
  end
  puts ""
end

# ── Report bootstrap token + token state ───────────────────────────────────

if defined?(System::BootstrapToken)
  token = System::BootstrapToken.where(node_instance: instance).order(created_at: :desc).first
  if token
    puts "  ── BootstrapToken issued ─────────────────────────────────────"
    puts "    id:                #{token.id}"
    puts "    intended_subject:  #{token.intended_subject}"
    puts "    expires_at:        #{token.expires_at}"
    puts "    consumed_at:       #{token.consumed_at || '(unconsumed)'}"
    puts "    purpose:           #{token.purpose}"
  else
    puts "    (no BootstrapToken row — adapter ran with token issuance disabled)"
  end
  puts ""
end

# ── Report final NodeInstance state ────────────────────────────────────────

instance.reload
puts "  ── NodeInstance after create ─────────────────────────────────────"
puts "    status:                    #{instance.status}"
puts "    cloud_instance_id:         #{instance.cloud_instance_id}"
puts "    last_heartbeat_at:         #{instance.last_heartbeat_at || '(none yet)'}"
puts "    running_module_digests:    #{instance.running_module_digests}"
puts ""

puts "  ✅ Smoke-test provision pass complete."
puts "     To clean up: System::Providers::Registry.for(connection).terminate_instance('powernode-smoke-#{instance.id[0..7]}')"
