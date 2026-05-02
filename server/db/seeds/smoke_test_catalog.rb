# frozen_string_literal: true

# Golden Eclipse — Smoke-test catalog seed.
#
# Creates the minimum DB content needed to provision a NodeInstance via
# LocalQemuProvider end-to-end:
#
#   NodeArchitecture (amd64)
#     └─ NodePlatform (Ubuntu 24.04 LTS)
#          └─ NodeTemplate (smoke-base)
#               └─ TemplateModule → NodeModule × 3 (system-base / apache / nginx)
#                                    └─ NodeModuleVersion (v1, fixture digest)
#
#   Provider (local_qemu) ── ProviderConnection (smoke-conn)
#     ├─ ProviderRegion (local)
#     └─ ProviderInstanceType (small / medium)
#
# Idempotent — every row uses find_or_create_by/find_or_initialize_by keyed on
# stable identifiers, so re-running the seed updates rather than duplicates.
#
# Invoke explicitly:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_catalog.rb')"
#
# Reference: Golden Eclipse plan M4 — local_qemu thin slice; user request
# 2026-05-02 ("complete node implementation including template, base modules,
# example service modules apache + nginx").

puts "\n  Seeding smoke-test catalog..."

account = Account.first
unless account
  puts "  ⚠️  No account — run platform seeds first; aborting smoke-test seed"
  return
end

# ── Architecture + platform ─────────────────────────────────────────────────

arch = System::NodeArchitecture.find_or_create_by!(account: account, name: "amd64") do |a|
  a.kernel_options = "console=ttyS0,115200 console=tty1 powernode.boot=1 ro"
  a.enabled = true
  a.public  = true
end
puts "    ✓ NodeArchitecture: amd64 (id=#{arch.id})"

platform = System::NodePlatform.find_or_create_by!(account: account, name: "ubuntu-24.04-lts") do |p|
  p.node_architecture = arch
  p.enabled       = true
  p.public        = true
  p.build_script  = "#!/bin/bash\nset -euo pipefail\n# Module rootfs build (mmdebstrap pinned to ubuntu 24.04)\nexec mmdebstrap --variant=minbase noble \"$@\"\n"
  p.init_script   = "#!/bin/bash\nset -euo pipefail\nexec /sbin/powernode-agent boot\n"
  p.sync_script   = "#!/bin/bash\nset -euo pipefail\nexec /sbin/powernode-agent sync\n"
end
puts "    ✓ NodePlatform: ubuntu-24.04-lts (id=#{platform.id})"

# ── Provider catalog (local_qemu) ───────────────────────────────────────────

provider = System::Provider.find_or_create_by!(account: account, provider_type: "local_qemu", name: "smoke-local-qemu") do |p|
  p.enabled = true
  p.config  = { "uri" => ENV.fetch("POWERNODE_LIBVIRT_URI", "qemu:///session") }
  p.capabilities = { "supports" => %w[provision start stop reboot terminate] }
end
puts "    ✓ Provider: smoke-local-qemu (id=#{provider.id}, type=local_qemu)"

connection = System::ProviderConnection.find_or_create_by!(account: account, provider: provider, name: "smoke-conn") do |c|
  c.access_key = "n/a-local"
  c.secret_key = "n/a-local"
  c.status     = "connected"
  c.config     = { "uri" => ENV.fetch("POWERNODE_LIBVIRT_URI", "qemu:///session") }
end
puts "    ✓ ProviderConnection: smoke-conn (status=#{connection.status})"

region = System::ProviderRegion.find_or_create_by!(account: account, provider: provider, region_code: "local") do |r|
  r.name        = "local"
  r.enabled     = true
  r.capabilities = {}
end
puts "    ✓ ProviderRegion: local (id=#{region.id})"

itype_small = System::ProviderInstanceType.find_or_create_by!(account: account, provider: provider, instance_type_code: "smoke.small") do |it|
  it.name       = "smoke.small"
  it.vcpus      = 1
  it.memory_mb  = 1024
  it.storage_gb = 4
  it.enabled    = true
end
itype_medium = System::ProviderInstanceType.find_or_create_by!(account: account, provider: provider, instance_type_code: "smoke.medium") do |it|
  it.name       = "smoke.medium"
  it.vcpus      = 2
  it.memory_mb  = 2048
  it.storage_gb = 8
  it.enabled    = true
end
puts "    ✓ ProviderInstanceType: smoke.small (#{itype_small.vcpus}/#{itype_small.memory_mb}MB), smoke.medium"

# Wire instance types to the region so provisioning can resolve them
[itype_small, itype_medium].each do |it|
  rit = System::RegionInstanceType.find_or_initialize_by(provider_region: region, provider_instance_type: it)
  rit.available = true
  rit.save!
end

# ── Module categories ───────────────────────────────────────────────────────

cat_base = System::NodeModuleCategory.find_or_create_by!(account: account, name: "smoke.base") do |c|
  c.position = 10
  c.variety  = "subscription"
  c.enabled  = true
end
cat_web = System::NodeModuleCategory.find_or_create_by!(account: account, name: "smoke.web") do |c|
  c.position = 50
  c.variety  = "subscription"
  c.enabled  = true
end
puts "    ✓ NodeModuleCategory: smoke.base, smoke.web"

# ── Modules + versions ──────────────────────────────────────────────────────

module_specs = [
  {
    name: "system-base",
    description: "Minimal Ubuntu 24.04 rootfs (mmdebstrap minbase) — every smoke node depends on this",
    category: cat_base,
    priority: 10,
    package_spec: %w[bash coreutils systemd systemd-networkd dbus iputils-ping iproute2 openssh-server ca-certificates curl],
    file_spec:    %w[/etc/** /usr/bin/** /usr/sbin/** /usr/lib/** /lib/** /sbin/** /bin/**],
    digest_seed:  "system-base-v1"
  },
  {
    name: "apache",
    description: "Apache 2.4 (mpm_event) — example web service module",
    category: cat_web,
    priority: 50,
    package_spec: %w[apache2 apache2-utils libapache2-mod-security2],
    file_spec:    %w[/etc/apache2/** /usr/sbin/apache2 /usr/lib/apache2/** /var/www/**],
    digest_seed:  "apache-v1"
  },
  {
    name: "nginx",
    description: "nginx 1.24 — example web service module (alternative to apache)",
    category: cat_web,
    priority: 50,
    package_spec: %w[nginx nginx-common],
    file_spec:    %w[/etc/nginx/** /usr/sbin/nginx /usr/share/nginx/** /var/www/**],
    digest_seed:  "nginx-v1"
  }
]

modules = {}
module_specs.each do |spec|
  m = System::NodeModule.find_or_create_by!(account: account, name: spec[:name]) do |mod|
    mod.node_platform = platform
    mod.category      = spec[:category]
    mod.variety       = "subscription"
    mod.priority      = spec[:priority]
    mod.description   = spec[:description]
  end

  v = System::NodeModuleVersion.find_or_initialize_by(node_module: m, version_number: 1)
  v.assign_attributes(
    mask:         [],
    file_spec:    spec[:file_spec],
    package_spec: spec[:package_spec],
    config:       {},
    oci_digest:   "sha256:#{Digest::SHA256.hexdigest(spec[:digest_seed])}",
    promotion_state: "live"
  )
  v.save!

  m.update!(current_version: v) if m.current_version_id != v.id

  modules[spec[:name]] = m
  puts "    ✓ NodeModule: #{spec[:name]} (priority=#{spec[:priority]}, v#{v.version_number}, digest=#{v.oci_digest[0..16]}…)"
end

# ── Templates ───────────────────────────────────────────────────────────────

template_specs = [
  { name: "smoke-base", modules: %w[system-base], description: "Bare smoke node — system-base only" },
  { name: "smoke-web-apache", modules: %w[system-base apache], description: "Smoke web node with apache" },
  { name: "smoke-web-nginx",  modules: %w[system-base nginx],  description: "Smoke web node with nginx" }
]

template_specs.each do |spec|
  t = System::NodeTemplate.find_or_create_by!(account: account, name: spec[:name]) do |tmpl|
    tmpl.node_platform = platform
    tmpl.enabled       = true
    tmpl.public        = false
    tmpl.admin_user    = "ubuntu"
    tmpl.description   = spec[:description]
    tmpl.config        = {}
  end

  spec[:modules].each_with_index do |mod_name, idx|
    m = modules[mod_name]
    tm = System::TemplateModule.find_or_initialize_by(node_template: t, node_module: m)
    tm.priority = (idx + 1) * 10
    tm.save!
  end
  puts "    ✓ NodeTemplate: #{t.name} → [#{spec[:modules].join(', ')}]"
end

puts "\n  ✅ Smoke-test catalog ready."
puts "     Provision: mcp__powernode__platform_system_create_node + system_provision_instance"
puts "     Templates: smoke-base / smoke-web-apache / smoke-web-nginx"
puts "     Provider:  smoke-local-qemu (uri=#{ENV.fetch('POWERNODE_LIBVIRT_URI', 'qemu:///session')})"
