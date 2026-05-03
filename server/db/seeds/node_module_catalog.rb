# frozen_string_literal: true

# Golden Eclipse — Node-module catalog seed.
#
# Creates the end-user-usable module + template catalog plus the minimal
# provider/region/instance-type infrastructure the local_qemu smoke tests
# need to exercise it end-to-end:
#
#   NodeArchitecture (amd64)
#     └─ NodePlatform (Ubuntu 24.04 LTS)
#          └─ NodeTemplate (base / hardened / web-apache / web-nginx)
#               └─ TemplateModule → NodeModule × 5 (system-base /
#                                    security-hardening / chrony / apache / nginx)
#                                    └─ NodeModuleVersion (v1, fixture digest)
#
#   Provider (local_qemu) ── ProviderConnection (smoke-conn)
#     ├─ ProviderRegion (local)
#     └─ ProviderInstanceType (small / medium)
#
# Modules + templates here are intended to be reusable starting points
# for real fleet deployments — only the provider/connection/instance-type
# rows are smoke-test scoped (their names retain a `smoke-` prefix to
# signal that). Renamed 2026-05-02 from smoke_test_catalog.rb after
# operator feedback that the artifacts were end-user-usable.
#
# Idempotent — every row uses find_or_create_by/find_or_initialize_by keyed on
# stable identifiers, so re-running the seed updates rather than duplicates.
#
# Invoke explicitly:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/node_module_catalog.rb')"

puts "\n  Seeding node-module catalog..."

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
    description: "Minimal Ubuntu 24.04 rootfs (mmdebstrap minbase) — every smoke node depends on this",
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

  spec[:modules].each_with_index do |mod_name, idx|
    m = modules[mod_name]
    tm = System::TemplateModule.find_or_initialize_by(node_template: t, node_module: m)
    tm.priority = (idx + 1) * 10
    tm.save!
  end
  puts "    ✓ NodeTemplate: #{t.name} → [#{spec[:modules].join(', ')}]"
end

puts "\n  ✅ Node-module catalog ready."
puts "     Provision: mcp__powernode__platform_system_create_node + system_provision_instance"
puts "     Templates: base / hardened / web-apache / web-nginx"
puts "     Provider:  smoke-local-qemu (uri=#{ENV.fetch('POWERNODE_LIBVIRT_URI', 'qemu:///session')})"
