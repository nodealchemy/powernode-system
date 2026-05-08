# frozen_string_literal: true

# System extension — Node-module catalog seed.
#
# Creates the end-user-usable module + template catalog plus the
# local_qemu provider infrastructure that operators (and integration
# tests) use to spin up VMs end-to-end:
#
#   NodeArchitecture (amd64, arm64)
#     ├─ NodePlatform (ubuntu-24.04-lts)
#     │    └─ NodeTemplate (base / hardened / web-apache / web-nginx)
#     │         └─ TemplateModule → NodeModule × N
#     │              └─ NodeModuleVersion (v1, fixture digest)
#     ├─ NodePlatform (ubuntu-24.04-rpi4)        — physical RPi 4
#     │    └─ NodeTemplate (rpi4-base, rpi4-hardened)
#     └─ NodePlatform (ubuntu-24.04-arm64-uefi)  — Pi 5 / Ampere / SBCs
#          └─ NodeTemplate (arm64-uefi-base)
#
#   Provider (local_qemu) ── ProviderConnection (qemu-conn)
#     ├─ ProviderRegion (local)
#     └─ ProviderInstanceType (qemu.small / qemu.medium)
#
# History:
#   - 2026-05-02: renamed from smoke_test_catalog.rb after operator
#     feedback that the artifacts were end-user-usable.
#   - 2026-05-02 (later): dropped the `smoke-` prefix on infrastructure
#     rows — these are general-purpose catalog entries, not smoke-test
#     scoped. The seed migrates existing rows in-place to preserve
#     foreign keys (RegionInstanceType, NodeInstance.provider_*_id).
#   - 2026-05-08 (M1 self-serve): the catalog body (architectures,
#     platforms, modules, categories, templates) was extracted into
#     `System::AccountBootstrapService.seed_templates_for(account)`
#     so the same code path runs at db:seed AND per-account on
#     `Account.after_create_commit`. The local-qemu dev/test
#     infrastructure stays here (operator-facing dev tooling, not
#     per-account scoped) along with the legacy cleanup logic.
#
# Idempotent: every row uses find_or_create_by/find_or_initialize_by
# keyed on stable identifiers. Re-running the seed updates rather than
# duplicates.
#
# Cleanup of stale smoke-test data (legacy nodes/instances/templates from
# prior smoke runs) is opt-in via CLEANUP_LEGACY=1 to avoid destroying
# in-progress operator work by surprise.
#
# Invoke explicitly:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/node_module_catalog.rb')"

puts "\n  Seeding node-module catalog..."

account = Account.first
unless account
  puts "  ⚠️  No account — run platform seeds first; aborting catalog seed"
  return
end

# ── In-place rename of legacy smoke-prefixed infrastructure ────────────────
#
# Earlier seed runs created infrastructure with `smoke-` prefixes when the
# catalog was thought to be smoke-test scoped. Drop the prefix in-place so
# foreign keys (RegionInstanceType, NodeInstance.provider_*_id) survive.
# Idempotent — finds nothing on second run.

infra_renames = {
  System::Provider             => { "smoke-local-qemu" => "local-qemu" },
  System::ProviderConnection   => { "smoke-conn"       => "qemu-conn" },
  System::ProviderInstanceType => { "smoke.small"      => "qemu.small",
                                    "smoke.medium"     => "qemu.medium" }
}
renamed = 0
infra_renames.each do |klass, mapping|
  mapping.each do |old_name, new_name|
    next if klass.where(account: account, name: new_name).exists?
    row = klass.find_by(account: account, name: old_name)
    next unless row
    extra = klass == System::ProviderInstanceType ? { instance_type_code: new_name } : {}
    row.update!(name: new_name, **extra)
    renamed += 1
    puts "    ↻ Renamed #{klass.name.demodulize}: #{old_name} → #{new_name}"
  end
end
puts "    ✓ Infrastructure renames: #{renamed} row(s) updated" if renamed.positive?

# ── Catalog (architectures + platforms + modules + categories + templates) ─
#
# Delegated to System::AccountBootstrapService so the same code path
# runs both here (db:seed → Account.first) and on Account.after_create
# (per new account).
modules = System::AccountBootstrapService.seed_templates_for(account, verbose: true)

# ── Provider catalog (local_qemu) ───────────────────────────────────────────
#
# Operator-facing dev/test infrastructure — NOT per-account-scoped, so
# kept here in the seed file rather than in the bootstrap service.

provider = System::Provider.find_or_create_by!(account: account, provider_type: "local_qemu", name: "local-qemu") do |p|
  p.enabled = true
  p.config  = { "uri" => ENV.fetch("POWERNODE_LIBVIRT_URI", "qemu:///session") }
  p.capabilities = { "supports" => %w[provision start stop reboot terminate] }
end
puts "    ✓ Provider: local-qemu (id=#{provider.id}, type=local_qemu)"

connection = System::ProviderConnection.find_or_create_by!(account: account, provider: provider, name: "qemu-conn") do |c|
  c.access_key = "n/a-local"
  c.secret_key = "n/a-local"
  c.status     = "connected"
  c.config     = { "uri" => ENV.fetch("POWERNODE_LIBVIRT_URI", "qemu:///session") }
end
puts "    ✓ ProviderConnection: qemu-conn (status=#{connection.status})"

region = System::ProviderRegion.find_or_create_by!(account: account, provider: provider, region_code: "local") do |r|
  r.name        = "local"
  r.enabled     = true
  r.capabilities = {}
end
puts "    ✓ ProviderRegion: local (id=#{region.id})"

itype_small = System::ProviderInstanceType.find_or_create_by!(account: account, provider: provider, instance_type_code: "qemu.small") do |it|
  it.name       = "qemu.small"
  it.vcpus      = 1
  it.memory_mb  = 1024
  it.storage_gb = 4
  it.enabled    = true
end
itype_medium = System::ProviderInstanceType.find_or_create_by!(account: account, provider: provider, instance_type_code: "qemu.medium") do |it|
  it.name       = "qemu.medium"
  it.vcpus      = 2
  it.memory_mb  = 2048
  it.storage_gb = 8
  it.enabled    = true
end
puts "    ✓ ProviderInstanceType: qemu.small (#{itype_small.vcpus}/#{itype_small.memory_mb}MB), qemu.medium"

# Wire instance types to the region so provisioning can resolve them
[itype_small, itype_medium].each do |it|
  rit = System::RegionInstanceType.find_or_initialize_by(provider_region: region, provider_instance_type: it)
  rit.available = true
  rit.save!
end

# ── Cleanup of legacy smoke-prefixed templates ──────────────────────────────
#
# Templates `smoke-base`, `smoke-web-apache`, `smoke-web-nginx` were created
# under the old naming. They've been superseded by the unprefixed names
# above. Destroy them along with their TemplateModule rows. Any node still
# pointing at them is repointed to `base` rather than detached since
# template choice is a deliberate decision and node_template_id is NOT NULL.

legacy_template_names = %w[smoke-base smoke-web-apache smoke-web-nginx]
legacy_templates = System::NodeTemplate.where(account: account, name: legacy_template_names)
if legacy_templates.any?
  legacy_count = legacy_templates.count
  fallback_template = System::NodeTemplate.find_by!(account: account, name: "base")
  affected_nodes = System::Node.where(node_template_id: legacy_templates.pluck(:id))
  if affected_nodes.any?
    affected_nodes.update_all(node_template_id: fallback_template.id)
    puts "    ↻ Repointed #{affected_nodes.count} Node(s) from legacy smoke templates → base"
  end
  legacy_templates.each do |t|
    t.template_modules.destroy_all
    t.destroy!
  end
  puts "    🧹 Removed #{legacy_count} legacy smoke template(s): #{legacy_template_names.join(', ')}"
end

# ── Cleanup of legacy smoke-prefixed module categories ─────────────────────

legacy_category_renames = {
  "smoke.base" => "base",
  "smoke.web"  => "web"
}
merged_categories = 0
legacy_category_renames.each do |old_name, new_name|
  legacy_cat = System::NodeModuleCategory.find_by(account: account, name: old_name)
  next unless legacy_cat
  canonical_cat = System::NodeModuleCategory.find_by(account: account, name: new_name)
  if canonical_cat
    affected = legacy_cat.node_modules.update_all(category_id: canonical_cat.id)
    puts "    ↻ Re-pointed #{affected} module(s) from #{old_name} → #{new_name}" if affected.positive?
    legacy_cat.destroy!
    merged_categories += 1
    puts "    🧹 Removed legacy NodeModuleCategory: #{old_name}"
  else
    legacy_cat.update!(name: new_name)
    merged_categories += 1
    puts "    ↻ Renamed NodeModuleCategory: #{old_name} → #{new_name}"
  end
end
puts "    ✓ Module category cleanups: #{merged_categories} row(s) processed" if merged_categories.positive?

# ── Optional: cleanup of legacy smoke-test nodes/instances ─────────────────
#
# Older smoke-test iterations left behind ~30 nodes (smoke-test-1,
# smoke-real-*, smoke-bridge-*, smoke-pivot-*, smoke-multi-*, preview).
# These are clearly stale — no real fleet uses these names — but we don't
# destroy them by default since a re-run of the seed during operator work
# shouldn't blow away in-flight state. Opt in with CLEANUP_LEGACY=1.

if ENV["CLEANUP_LEGACY"] == "1"
  legacy_node_patterns = [
    /\Asmoke-test-/, /\Asmoke-real-/, /\Asmoke-bridge-/, /\Asmoke-pivot-/,
    /\Asmoke-multi-/, /\Apreview\z/, /\Acurl-test/
  ]
  legacy_nodes = System::Node.where(account: account).select do |n|
    legacy_node_patterns.any? { |p| n.name.match?(p) }
  end

  destroy_instance = lambda do |inst|
    inst_id = inst.id
    System::NodeModule.where(node_instance_id: inst_id).update_all(node_instance_id: nil) if defined?(System::NodeModule)
    System::BootstrapToken.where(node_instance_id: inst_id).update_all(node_instance_id: nil) if defined?(System::BootstrapToken)
    System::ProviderVolume.where(node_instance_id: inst_id).update_all(node_instance_id: nil) if defined?(System::ProviderVolume)
    System::UnclaimedDevice.where(claimed_node_instance_id: inst_id).update_all(claimed_node_instance_id: nil) if defined?(System::UnclaimedDevice)
    System::NodeCertificate.where(node_instance_id: inst_id).destroy_all if defined?(System::NodeCertificate)
    System::InstanceMountPoint.where(node_instance_id: inst_id).destroy_all if defined?(System::InstanceMountPoint)
    inst.destroy!
  end

  destroy_node = lambda do |node|
    node_id = node.id
    System::NodeModule.where(node_id: node_id).update_all(node_id: nil) if defined?(System::NodeModule)
    System::BootstrapToken.where(node_id: node_id).destroy_all if defined?(System::BootstrapToken)
    System::NodeModuleAssignment.where(node_id: node_id).destroy_all if defined?(System::NodeModuleAssignment)
    node.destroy!
  end

  if legacy_nodes.any?
    inst_count = legacy_nodes.sum { |n| n.node_instances.count }
    legacy_nodes.each do |n|
      n.node_instances.each { |inst| destroy_instance.call(inst) }
      destroy_node.call(n)
    end
    puts "    🧹 CLEANUP_LEGACY: removed #{legacy_nodes.length} legacy node(s) + #{inst_count} instance(s)"
  end
end

puts "\n  ✅ Node-module catalog ready."
puts "     Templates: base / hardened / web-apache / web-nginx (amd64)"
puts "                rpi4-base / rpi4-hardened (arm64 / RPi 4)"
puts "                arm64-uefi-base (arm64 / generic UEFI)"
puts "     Provider:  local-qemu (uri=#{ENV.fetch('POWERNODE_LIBVIRT_URI', 'qemu:///session')})"
puts "     Tip:       set CLEANUP_LEGACY=1 to also destroy legacy smoke-test nodes/instances"
