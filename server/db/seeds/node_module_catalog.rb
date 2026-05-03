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

# ── Architecture + platform ─────────────────────────────────────────────────

arch = System::NodeArchitecture.find_or_create_by!(account: account, name: "amd64") do |a|
  a.kernel_options = "console=ttyS0,115200 console=tty1 powernode.boot=1 ro"
  a.enabled = true
  a.public  = true
end
puts "    ✓ NodeArchitecture: amd64 (id=#{arch.id})"

# arm64 architecture for physical-device support (RPi 4 + generic UEFI SBCs).
# Plan: wondrous-yawning-anchor.md — Phase 1 hardware scope.
arch_arm64 = System::NodeArchitecture.find_or_create_by!(account: account, name: "arm64") do |a|
  a.kernel_options = "console=serial0,115200 console=tty1 powernode.boot=1 ro"
  a.enabled = true
  a.public  = true
end
puts "    ✓ NodeArchitecture: arm64 (id=#{arch_arm64.id})"

platform = System::NodePlatform.find_or_create_by!(account: account, name: "ubuntu-24.04-lts") do |p|
  p.node_architecture = arch
  p.enabled       = true
  p.public        = true
  p.build_script  = "#!/bin/bash\nset -euo pipefail\n# Module rootfs build (mmdebstrap pinned to ubuntu 24.04)\nexec mmdebstrap --variant=minbase noble \"$@\"\n"
  p.init_script   = "#!/bin/bash\nset -euo pipefail\nexec /sbin/powernode-agent boot\n"
  p.sync_script   = "#!/bin/bash\nset -euo pipefail\nexec /sbin/powernode-agent sync\n"
end
puts "    ✓ NodePlatform: ubuntu-24.04-lts (id=#{platform.id})"

# Raspberry Pi 4 platform — MBR + FAT32 boot partition with /boot/firmware/
# layout. Operators flash the disk image onto an SD card, plug the Pi in,
# the agent boots and polls /node_api/claim until the operator confirms.
# See plan wondrous-yawning-anchor.md §3 for the build pipeline + §5 for
# the claim flow.
platform_rpi4 = System::NodePlatform.find_or_create_by!(account: account, name: "ubuntu-24.04-rpi4") do |p|
  p.node_architecture = arch_arm64
  p.enabled       = true
  p.public        = true
  p.build_script  = "#!/bin/bash\nset -euo pipefail\nexec mmdebstrap --variant=minbase --architectures=arm64 noble \"$@\"\n"
  p.init_script   = "#!/bin/bash\nset -euo pipefail\nexec /sbin/powernode-agent boot\n"
  p.sync_script   = "#!/bin/bash\nset -euo pipefail\nexec /sbin/powernode-agent sync\n"
end
puts "    ✓ NodePlatform: ubuntu-24.04-rpi4 (id=#{platform_rpi4.id})"

# Generic arm64 UEFI platform — Pi 5 with UEFI Pi firmware, Ampere boards,
# Lenovo ThinkSystem arm64, etc. Uses the existing GPT layout via the
# images/raw/ build script.
platform_arm64_uefi = System::NodePlatform.find_or_create_by!(account: account, name: "ubuntu-24.04-arm64-uefi") do |p|
  p.node_architecture = arch_arm64
  p.enabled       = true
  p.public        = true
  p.build_script  = "#!/bin/bash\nset -euo pipefail\nexec mmdebstrap --variant=minbase --architectures=arm64 noble \"$@\"\n"
  p.init_script   = "#!/bin/bash\nset -euo pipefail\nexec /sbin/powernode-agent boot\n"
  p.sync_script   = "#!/bin/bash\nset -euo pipefail\nexec /sbin/powernode-agent sync\n"
end
puts "    ✓ NodePlatform: ubuntu-24.04-arm64-uefi (id=#{platform_arm64_uefi.id})"

# ── Provider catalog (local_qemu) ───────────────────────────────────────────

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

# ── Module categories ───────────────────────────────────────────────────────

cat_base = System::NodeModuleCategory.find_or_create_by!(account: account, name: "base") do |c|
  c.position = 10
  c.variety  = "subscription"
  c.enabled  = true
end
cat_security = System::NodeModuleCategory.find_or_create_by!(account: account, name: "security") do |c|
  c.position = 20
  c.variety  = "subscription"
  c.enabled  = true
end
cat_time = System::NodeModuleCategory.find_or_create_by!(account: account, name: "time") do |c|
  c.position = 30
  c.variety  = "subscription"
  c.enabled  = true
end
cat_web = System::NodeModuleCategory.find_or_create_by!(account: account, name: "web") do |c|
  c.position = 50
  c.variety  = "subscription"
  c.enabled  = true
end
# Hardware-specific firmware sits between system-base (priority 10) and the
# security floor (priority 20) so the boot partition is established before
# any policy is applied. Per plan wondrous-yawning-anchor.md.
cat_firmware = System::NodeModuleCategory.find_or_create_by!(account: account, name: "firmware") do |c|
  c.position = 15
  c.variety  = "subscription"
  c.enabled  = true
end
puts "    ✓ NodeModuleCategory: base, firmware, security, time, web"

# ── Modules + versions ──────────────────────────────────────────────────────

module_specs = [
  {
    name: "system-base",
    description: "Minimal Ubuntu 24.04 rootfs (mmdebstrap minbase) — every node depends on this",
    category: cat_base,
    priority: 10,
    package_spec: %w[bash coreutils systemd systemd-networkd dbus iputils-ping iproute2 openssh-server ca-certificates curl],
    file_spec:    %w[/etc/** /usr/bin/** /usr/sbin/** /usr/lib/** /lib/** /sbin/** /bin/**],
    mask:         %w[/var/cache/apt/** /var/lib/apt/lists/** /usr/share/doc/** /usr/share/man/** /usr/share/locale/** /var/log/**],
    # Sensitive paths system-base owns. No higher-priority module may ship
    # any of these — the build pipeline folds them into every higher
    # neighbor's effective_mask.
    protected_spec: %w[
      /etc/passwd
      /etc/shadow
      /etc/group
      /etc/gshadow
      /etc/sudoers
      /etc/sudoers.d/**
      /etc/pam.d/**
      /etc/security/**
      /etc/login.defs
      /etc/ssh/sshd_config
      /etc/ssh/sshd_config.d/**
      /etc/ssh/ssh_host_*_key
      /etc/ssh/ssh_host_*_key.pub
      /etc/systemd/system/powernode-agent.service
      /usr/sbin/powernode-agent
      /sbin/powernode-agent
      /usr/bin/sudo
      /usr/bin/su
      /usr/sbin/sshd
    ],
    digest_seed:  "system-base-v1"
  },
  {
    name: "security-hardening",
    description: "Baseline sysctl + ulimits + modprobe blacklist + AppArmor + auditd — pre-services hardening floor",
    category: cat_security,
    priority: 20,
    package_spec: %w[apparmor apparmor-profiles apparmor-utils auditd libpam-tmpdir],
    file_spec:    %w[/etc/sysctl.d/** /etc/security/limits.d/** /etc/apparmor.d/** /etc/audit/auditd.conf /etc/audit/rules.d/** /etc/modprobe.d/blacklist-powernode.conf],
    mask:         %w[/var/cache/apt/** /var/lib/apt/lists/** /usr/share/doc/** /usr/share/man/** /var/log/**],
    # Hardening floor — no higher module may erode these defaults via
    # union-mount overrides. Service modules that need a relaxed value
    # must use a dependant child (operator-approved) instead.
    protected_spec: %w[
      /etc/sysctl.d/99-powernode-baseline.conf
      /etc/security/limits.d/99-powernode-baseline.conf
      /etc/modprobe.d/blacklist-powernode.conf
    ],
    digest_seed:  "security-hardening-v1"
  },
  {
    name: "chrony",
    description: "chrony NTP client — accurate time, NTP trust anchor protected from override",
    category: cat_time,
    priority: 30,
    package_spec: %w[chrony],
    file_spec:    %w[/etc/chrony/** /usr/sbin/chronyd /usr/bin/chronyc /lib/systemd/system/chrony.service /lib/systemd/system/chronyd.service /etc/systemd/system/chrony.service.d/**],
    mask:         %w[/var/cache/apt/** /var/lib/apt/lists/** /usr/share/doc/** /usr/share/man/** /var/log/chrony/**],
    # NTP trust anchor — flipping this is a clock-skew exploitation vector
    # (TLS validity, log integrity, Kerberos). Higher modules can't ship.
    protected_spec: %w[
      /etc/chrony/chrony.conf
      /etc/chrony/conf.d/**
      /etc/chrony/sources.d/**
    ],
    digest_seed:  "chrony-v1"
  },
  {
    name: "apache",
    description: "Apache 2.4 (mpm_event) — example web service module",
    category: cat_web,
    priority: 50,
    package_spec: %w[apache2 apache2-utils libapache2-mod-security2],
    file_spec:    %w[/etc/apache2/** /usr/sbin/apache2 /usr/sbin/apache2ctl /usr/lib/apache2/** /usr/share/apache2/** /etc/init.d/apache2 /etc/logrotate.d/apache2 /lib/systemd/system/apache2.service /var/www/**],
    mask:         %w[/var/cache/apt/** /var/lib/apt/lists/** /usr/share/doc/** /usr/share/man/** /var/log/apache2/**],
    protected_spec: [],
    digest_seed:  "apache-v1"
  },
  {
    name: "nginx",
    description: "nginx 1.24 — example web service module (alternative to apache)",
    category: cat_web,
    priority: 50,
    package_spec: %w[nginx nginx-common],
    file_spec:    %w[/etc/nginx/** /usr/sbin/nginx /usr/share/nginx/** /etc/init.d/nginx /etc/logrotate.d/nginx /lib/systemd/system/nginx.service /var/www/**],
    mask:         %w[/var/cache/apt/** /var/lib/apt/lists/** /usr/share/doc/** /usr/share/man/** /var/log/nginx/**],
    protected_spec: [],
    digest_seed:  "nginx-v1"
  },
  {
    # RPi 4 firmware module — ships GPU bootloader + DTBs + config.txt /
    # cmdline.txt templates into the FAT32 boot partition. Sourced at CI
    # build time from upstream raspberrypi/firmware repo (per Broadcom
    # redistribution license, NOT committed to this repo).
    name: "rpi4-firmware",
    description: "Raspberry Pi 4 firmware (start4.elf, fixup4.dat, bcm2711-rpi-4-b.dtb, overlays, config.txt, cmdline.txt). Required for booting the RPi 4 from a Powernode disk image.",
    category: cat_firmware,
    priority: 15,
    package_spec: [],
    # All paths land in /boot/firmware/ — the FAT32 boot partition mount
    # point used by the rpi4 disk-image builder.
    file_spec:    %w[/boot/firmware/start4.elf /boot/firmware/fixup4.dat /boot/firmware/bcm2711-rpi-4-b.dtb /boot/firmware/overlays/** /boot/firmware/config.txt /boot/firmware/cmdline.txt],
    mask:         %w[/var/cache/apt/** /var/lib/apt/lists/** /usr/share/doc/**],
    # Hardware boot path is non-negotiable — no other module may shadow
    # firmware files (a misconfigured overlay would brick the device).
    protected_spec: %w[/boot/firmware/start4.elf /boot/firmware/fixup4.dat /boot/firmware/bcm2711-rpi-4-b.dtb /boot/firmware/config.txt],
    digest_seed:  "rpi4-firmware-v1"
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

  # Mirror the spec arrays onto the module itself (the in-DB authoritative
  # copy that effective_mask + rsync_spec read from) before snapshotting
  # to a NodeModuleVersion. Earlier versions of this seed left the
  # NodeModule rows with empty masks and only populated the version, which
  # broke effective_mask computations against a live node.
  #
  # IMPORTANT: pass spec arrays as newline-joined strings so the
  # `encode_specs` before_validation callback base64-encodes each line.
  # Passing a raw array bypasses the callback (it only encodes Strings),
  # which leaves the column with plain-string entries that subsequent
  # base64-decoding then turns into garbage. encode_spec_array makes
  # this conversion explicit.
  encode_spec_array = ->(arr) { Array(arr).join("\n") }

  m.update!(
    description:    spec[:description],
    mask:           encode_spec_array.call(spec[:mask]),
    file_spec:      encode_spec_array.call(spec[:file_spec]),
    package_spec:   encode_spec_array.call(spec[:package_spec]),
    protected_spec: encode_spec_array.call(spec[:protected_spec])
  )

  # NodeModuleVersion does not have the encode_specs callback (it's a
  # snapshot, not the live editing surface), so we encode each line
  # explicitly here to keep the wire shape consistent across both
  # tables and the API serializer.
  encoded = ->(arr) { Array(arr).map { |line| Base64.strict_encode64(line.to_s) }.sort.uniq }

  v = System::NodeModuleVersion.find_or_initialize_by(node_module: m, version_number: 1)
  v.assign_attributes(
    mask:           encoded.call(spec[:mask]),
    file_spec:      encoded.call(spec[:file_spec]),
    package_spec:   encoded.call(spec[:package_spec]),
    protected_spec: encoded.call(spec[:protected_spec]),
    config:         {},
    oci_digest:     "sha256:#{Digest::SHA256.hexdigest(spec[:digest_seed])}",
    promotion_state: "live"
  )
  v.save!

  m.update!(current_version: v) if m.current_version_id != v.id

  modules[spec[:name]] = m
  puts "    ✓ NodeModule: #{spec[:name]} (priority=#{spec[:priority]}, v#{v.version_number}, digest=#{v.oci_digest[0..16]}…)"
end

# ── Templates ───────────────────────────────────────────────────────────────

template_specs = [
  { name: "base", modules: %w[system-base], description: "Bare node — system-base only", platform: platform },
  { name: "hardened", modules: %w[system-base security-hardening chrony],
    description: "Hardened baseline — system-base + sysctl/AppArmor floor + chrony time sync, no service tier",
    platform: platform },
  { name: "web-apache", modules: %w[system-base security-hardening chrony apache],
    description: "Hardened web node with apache", platform: platform },
  { name: "web-nginx",  modules: %w[system-base security-hardening chrony nginx],
    description: "Hardened web node with nginx", platform: platform },
  # Physical-device templates (Phase 1 hardware scope, plan wondrous-yawning-anchor.md).
  { name: "rpi4-base", modules: %w[system-base rpi4-firmware],
    description: "Raspberry Pi 4 baseline — system-base + RPi firmware. Flash to SD card, plug Pi in, claim via UI.",
    platform: platform_rpi4 },
  { name: "rpi4-hardened", modules: %w[system-base rpi4-firmware security-hardening chrony],
    description: "Hardened Raspberry Pi 4 — base + hardening floor + time sync.",
    platform: platform_rpi4 },
  { name: "arm64-uefi-base", modules: %w[system-base],
    description: "Generic arm64 UEFI baseline — Pi 5 with UEFI Pi firmware, Ampere boards, etc.",
    platform: platform_arm64_uefi }
]

template_specs.each do |spec|
  t = System::NodeTemplate.find_or_create_by!(account: account, name: spec[:name]) do |tmpl|
    tmpl.node_platform = spec[:platform] || platform
    tmpl.enabled       = true
    tmpl.public        = false
    tmpl.admin_user    = "ubuntu"
    tmpl.description   = spec[:description]
    tmpl.config        = {}
  end
  # Update mutable fields on existing rows (description/platform may have shifted across seed revisions).
  t.update!(description: spec[:description], node_platform: spec[:platform] || platform) if t.description != spec[:description] || t.node_platform_id != (spec[:platform] || platform).id

  spec[:modules].each_with_index do |mod_name, idx|
    m = modules[mod_name]
    tm = System::TemplateModule.find_or_initialize_by(node_template: t, node_module: m)
    tm.priority = (idx + 1) * 10
    tm.save!
  end

  # Drop TemplateModule rows for modules no longer in the spec.
  desired_module_ids = spec[:modules].map { |n| modules[n].id }
  stale_tms = t.template_modules.where.not(node_module_id: desired_module_ids)
  if stale_tms.any?
    removed = stale_tms.count
    stale_tms.destroy_all
    puts "      ↻ Removed #{removed} stale TemplateModule(s) from #{t.name}"
  end

  puts "    ✓ NodeTemplate: #{t.name} → [#{spec[:modules].join(', ')}]"
end

# ── Cleanup of legacy smoke-prefixed templates ──────────────────────────────
#
# Templates `smoke-base`, `smoke-web-apache`, `smoke-web-nginx` were created
# under the old naming. They've been superseded by the unprefixed names
# above. Destroy them along with their TemplateModule rows. Any node still
# pointing at them is detached (set to NULL) — operators must repoint
# manually since template choice is a deliberate decision.

legacy_template_names = %w[smoke-base smoke-web-apache smoke-web-nginx]
legacy_templates = System::NodeTemplate.where(account: account, name: legacy_template_names)
if legacy_templates.any?
  legacy_count = legacy_templates.count
  fallback_template = System::NodeTemplate.find_by!(account: account, name: "base")
  affected_nodes = System::Node.where(node_template_id: legacy_templates.pluck(:id))
  if affected_nodes.any?
    # node_template_id is NOT NULL — repoint to `base` rather than detach.
    # Operators can pick a more appropriate template later; the rows
    # survive so in-flight work isn't blown away.
    affected_nodes.update_all(node_template_id: fallback_template.id)
    puts "    ↻ Repointed #{affected_nodes.count} Node(s) from legacy smoke templates → base"
  end
  legacy_templates.each do |t|
    t.template_modules.destroy_all
    t.destroy!
  end
  puts "    🧹 Removed #{legacy_count} legacy smoke template(s): #{legacy_template_names.join(', ')}"
end

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

  # Helper: cascade-destroy a NodeInstance by nulling out nullable FKs
  # first (preserves audit trails), then destroying the NOT NULL
  # dependents (mount points, certificates), then the instance itself.
  # Schema FKs default to NO ACTION rather than CASCADE, so this has
  # to be explicit — the destroy! callback chain doesn't handle them.
  destroy_instance = lambda do |inst|
    inst_id = inst.id
    # Nullable FKs — preserve history.
    System::NodeModule.where(node_instance_id: inst_id).update_all(node_instance_id: nil) if defined?(System::NodeModule)
    System::BootstrapToken.where(node_instance_id: inst_id).update_all(node_instance_id: nil) if defined?(System::BootstrapToken)
    System::ProviderVolume.where(node_instance_id: inst_id).update_all(node_instance_id: nil) if defined?(System::ProviderVolume)
    System::UnclaimedDevice.where(claimed_node_instance_id: inst_id).update_all(claimed_node_instance_id: nil) if defined?(System::UnclaimedDevice)
    # NOT NULL FKs — must destroy.
    System::NodeCertificate.where(node_instance_id: inst_id).destroy_all if defined?(System::NodeCertificate)
    System::InstanceMountPoint.where(node_instance_id: inst_id).destroy_all if defined?(System::InstanceMountPoint)
    inst.destroy!
  end

  # Node-level dependents (NodeModule, BootstrapToken, NodeModuleAssignment).
  # Same NO ACTION FK story — clean explicitly before destroy.
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
