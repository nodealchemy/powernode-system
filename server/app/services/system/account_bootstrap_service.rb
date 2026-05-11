# frozen_string_literal: true

module System
  # Per-account System extension bootstrap.
  #
  # Creates the cloud-provider scaffold (Provider + Regions +
  # InstanceTypes) and the node-module catalog (Architectures +
  # Platforms + Categories + Modules + Templates) that every new account
  # needs to start spinning up nodes through the Self-Serve Pro Cloud
  # activation funnel.
  #
  # Idempotent: every row is keyed on stable identifiers and uses
  # `find_or_create_by!`. Re-running for an existing account is a no-op.
  #
  # Invocation:
  #   - Auto-fired by `Account.after_create_commit :run_account_bootstrap`
  #   - Re-runnable manually: `System::AccountBootstrapService.call(account)`
  #   - The legacy `node_module_catalog.rb` db:seed file delegates the
  #     catalog body to `seed_templates_for(account, verbose: true)` so
  #     the same code path runs at db:seed AND per-account.
  class AccountBootstrapService
    DEFAULT_PROVIDER_NAME = "Pro Cloud"
    DEFAULT_PROVIDER_TYPE = "pro_cloud"

    DEFAULT_REGIONS = [
      { name: "us-east", region_code: "us-east-1" },
      { name: "us-west", region_code: "us-west-1" }
    ].freeze

    DEFAULT_INSTANCE_TYPES = [
      { name: "tiny",   instance_type_code: "vc2-1c-1gb", vcpus: 1, memory_mb: 1024, hourly_price: 0.007 },
      { name: "small",  instance_type_code: "vc2-1c-2gb", vcpus: 1, memory_mb: 2048, hourly_price: 0.018 },
      { name: "medium", instance_type_code: "vc2-2c-4gb", vcpus: 2, memory_mb: 4096, hourly_price: 0.036 }
    ].freeze

    # ---- Public API ---------------------------------------------------

    def self.call(account)
      new(account).call
    end

    def initialize(account)
      @account = account
    end

    def call
      return nil if @account.nil?

      seed_provider!
      seed_regions!
      seed_instance_types!
      seed_templates!
      @account
    end

    # ---- Class methods (used by both bootstrap + db:seed) ------------

    # Catalog seed body — extracted from
    # extensions/system/server/db/seeds/node_module_catalog.rb so the
    # same logic runs at db:seed AND per-account on Account.after_create.
    #
    # `verbose:` controls progress output. The bootstrap path keeps
    # quiet; the seed file flips it on.
    def self.seed_templates_for(account, verbose: false)
      return nil if account.nil?

      log = ->(msg) { puts msg if verbose }

      # ── Architectures ────────────────────────────────────────────────
      #
      # NodeArchitecture is platform-wide as of i-would-like-to-zesty-glade.md
      # (Tier 1). Migrations seed canonicals in dev/prod; test environments
      # only run schema:load (no migrations), so ensure_canonical_seed!
      # idempotently materializes them on first bootstrap call.
      ::System::NodeArchitecture.ensure_canonical_seed!
      arch = ::System::NodeArchitecture.canonical.find_by!(name: "amd64")
      log.call("    ✓ NodeArchitecture: #{arch.name} (id=#{arch.id})")

      arch_arm64 = ::System::NodeArchitecture.canonical.find_by!(name: "arm64")
      log.call("    ✓ NodeArchitecture: #{arch_arm64.name} (id=#{arch_arm64.id})")

      # ── Platforms ────────────────────────────────────────────────────
      platform = ::System::NodePlatform.find_or_create_by!(account: account, name: "ubuntu-24.04-lts") do |p|
        p.node_architecture = arch
        p.enabled       = true
        p.public        = true
        p.build_script  = "#!/bin/bash\nset -euo pipefail\n# Module rootfs build (mmdebstrap pinned to ubuntu 24.04)\nexec mmdebstrap --variant=minbase noble \"$@\"\n"
        p.init_script   = "#!/bin/bash\nset -euo pipefail\nexec /sbin/powernode-agent boot\n"
        p.sync_script   = "#!/bin/bash\nset -euo pipefail\nexec /sbin/powernode-agent sync\n"
      end
      log.call("    ✓ NodePlatform: ubuntu-24.04-lts (id=#{platform.id})")

      platform_rpi4 = ::System::NodePlatform.find_or_create_by!(account: account, name: "ubuntu-24.04-rpi4") do |p|
        p.node_architecture = arch_arm64
        p.enabled       = true
        p.public        = true
        p.build_script  = "#!/bin/bash\nset -euo pipefail\nexec mmdebstrap --variant=minbase --architectures=arm64 noble \"$@\"\n"
        p.init_script   = "#!/bin/bash\nset -euo pipefail\nexec /sbin/powernode-agent boot\n"
        p.sync_script   = "#!/bin/bash\nset -euo pipefail\nexec /sbin/powernode-agent sync\n"
      end
      log.call("    ✓ NodePlatform: ubuntu-24.04-rpi4 (id=#{platform_rpi4.id})")

      platform_arm64_uefi = ::System::NodePlatform.find_or_create_by!(account: account, name: "ubuntu-24.04-arm64-uefi") do |p|
        p.node_architecture = arch_arm64
        p.enabled       = true
        p.public        = true
        p.build_script  = "#!/bin/bash\nset -euo pipefail\nexec mmdebstrap --variant=minbase --architectures=arm64 noble \"$@\"\n"
        p.init_script   = "#!/bin/bash\nset -euo pipefail\nexec /sbin/powernode-agent boot\n"
        p.sync_script   = "#!/bin/bash\nset -euo pipefail\nexec /sbin/powernode-agent sync\n"
      end
      log.call("    ✓ NodePlatform: ubuntu-24.04-arm64-uefi (id=#{platform_arm64_uefi.id})")

      # ── Cosign trust policy backfill (only sets when blank) ─────────
      [platform, platform_rpi4, platform_arm64_uefi].each do |p|
        attrs = {}
        attrs[:cosign_identity_regexp] = "https://registry.example.com/powernode/.+" if p.cosign_identity_regexp.blank?
        attrs[:cosign_issuer_regexp]   = "https://registry.example.com"              if p.cosign_issuer_regexp.blank?
        next if attrs.empty?
        p.update!(attrs)
        log.call("    ↻ NodePlatform: #{p.name} cosign trust policy seeded")
      end

      # ── Module categories ────────────────────────────────────────────
      cat_base = ::System::NodeModuleCategory.find_or_create_by!(account: account, name: "base") do |c|
        c.position = 10
        c.variety  = "subscription"
        c.enabled  = true
      end
      cat_security = ::System::NodeModuleCategory.find_or_create_by!(account: account, name: "security") do |c|
        c.position = 20
        c.variety  = "subscription"
        c.enabled  = true
      end
      cat_time = ::System::NodeModuleCategory.find_or_create_by!(account: account, name: "time") do |c|
        c.position = 30
        c.variety  = "subscription"
        c.enabled  = true
      end
      cat_web = ::System::NodeModuleCategory.find_or_create_by!(account: account, name: "web") do |c|
        c.position = 50
        c.variety  = "subscription"
        c.enabled  = true
      end
      cat_firmware = ::System::NodeModuleCategory.find_or_create_by!(account: account, name: "firmware") do |c|
        c.position = 15
        c.variety  = "subscription"
        c.enabled  = true
      end
      log.call("    ✓ NodeModuleCategory: base, firmware, security, time, web")

      # ── Modules + versions ───────────────────────────────────────────
      module_specs = [
        {
          name: "system-base",
          description: "Minimal Ubuntu 24.04 rootfs (mmdebstrap minbase) — every node depends on this",
          category: cat_base,
          priority: 10,
          package_spec: %w[bash coreutils systemd systemd-networkd dbus iputils-ping iproute2 openssh-server ca-certificates curl],
          file_spec:    %w[/etc/** /usr/bin/** /usr/sbin/** /usr/lib/** /lib/** /sbin/** /bin/**],
          mask:         %w[/var/cache/apt/** /var/lib/apt/lists/** /usr/share/doc/** /usr/share/man/** /usr/share/locale/** /var/log/**],
          protected_spec: %w[
            /etc/passwd /etc/shadow /etc/group /etc/gshadow /etc/sudoers /etc/sudoers.d/**
            /etc/pam.d/** /etc/security/** /etc/login.defs /etc/ssh/sshd_config
            /etc/ssh/sshd_config.d/** /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub
            /etc/systemd/system/powernode-agent.service /usr/sbin/powernode-agent
            /sbin/powernode-agent /usr/bin/sudo /usr/bin/su /usr/sbin/sshd
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
          protected_spec: %w[/etc/chrony/chrony.conf /etc/chrony/conf.d/** /etc/chrony/sources.d/**],
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
          name: "rpi4-firmware",
          description: "Raspberry Pi 4 firmware (start4.elf, fixup4.dat, bcm2711-rpi-4-b.dtb, overlays, config.txt, cmdline.txt). Required for booting the RPi 4 from a Powernode disk image.",
          category: cat_firmware,
          priority: 15,
          package_spec: [],
          file_spec:    %w[/boot/firmware/start4.elf /boot/firmware/fixup4.dat /boot/firmware/bcm2711-rpi-4-b.dtb /boot/firmware/overlays/** /boot/firmware/config.txt /boot/firmware/cmdline.txt],
          mask:         %w[/var/cache/apt/** /var/lib/apt/lists/** /usr/share/doc/**],
          protected_spec: %w[/boot/firmware/start4.elf /boot/firmware/fixup4.dat /boot/firmware/bcm2711-rpi-4-b.dtb /boot/firmware/config.txt],
          digest_seed:  "rpi4-firmware-v1"
        }
      ]

      modules = {}
      module_specs.each do |spec|
        m = ::System::NodeModule.find_or_create_by!(account: account, name: spec[:name]) do |mod|
          mod.node_platform = platform
          mod.category      = spec[:category]
          mod.variety       = "subscription"
          mod.priority      = spec[:priority]
          mod.description   = spec[:description]
        end

        # IMPORTANT: pass spec arrays as newline-joined strings so the
        # `encode_specs` before_validation callback base64-encodes each
        # line. (See seed comment for history of this bug.)
        encode_spec_array = ->(arr) { Array(arr).join("\n") }

        m.update!(
          description:    spec[:description],
          mask:           encode_spec_array.call(spec[:mask]),
          file_spec:      encode_spec_array.call(spec[:file_spec]),
          package_spec:   encode_spec_array.call(spec[:package_spec]),
          protected_spec: encode_spec_array.call(spec[:protected_spec])
        )

        encoded = ->(arr) { Array(arr).map { |line| Base64.strict_encode64(line.to_s) }.sort.uniq }

        v = ::System::NodeModuleVersion.find_or_initialize_by(node_module: m, version_number: 1)
        v.assign_attributes(
          mask:            encoded.call(spec[:mask]),
          file_spec:       encoded.call(spec[:file_spec]),
          package_spec:    encoded.call(spec[:package_spec]),
          protected_spec:  encoded.call(spec[:protected_spec]),
          config:          {},
          oci_digest:      "sha256:#{Digest::SHA256.hexdigest(spec[:digest_seed])}",
          promotion_state: "live"
        )
        v.save!

        m.update!(current_version: v) if m.current_version_id != v.id

        modules[spec[:name]] = m
        log.call("    ✓ NodeModule: #{spec[:name]} (priority=#{spec[:priority]}, v#{v.version_number})")
      end

      # ── Templates ────────────────────────────────────────────────────
      template_specs = [
        { name: "base", modules: %w[system-base], description: "Bare node — system-base only", platform: platform },
        { name: "hardened", modules: %w[system-base security-hardening chrony],
          description: "Hardened baseline — system-base + sysctl/AppArmor floor + chrony time sync, no service tier",
          platform: platform },
        { name: "web-apache", modules: %w[system-base security-hardening chrony apache],
          description: "Hardened web node with apache", platform: platform },
        { name: "web-nginx",  modules: %w[system-base security-hardening chrony nginx],
          description: "Hardened web node with nginx", platform: platform },
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
        t = ::System::NodeTemplate.find_or_create_by!(account: account, name: spec[:name]) do |tmpl|
          tmpl.node_platform = spec[:platform] || platform
          tmpl.enabled       = true
          tmpl.public        = false
          tmpl.admin_user    = "ubuntu"
          tmpl.description   = spec[:description]
          tmpl.config        = {}
        end

        if t.description != spec[:description] || t.node_platform_id != (spec[:platform] || platform).id
          t.update!(description: spec[:description], node_platform: spec[:platform] || platform)
        end

        spec[:modules].each_with_index do |mod_name, idx|
          m = modules[mod_name]
          tm = ::System::TemplateModule.find_or_initialize_by(node_template: t, node_module: m)
          tm.priority = (idx + 1) * 10
          tm.save!
        end

        # Drop TemplateModule rows for modules no longer in the spec.
        desired_module_ids = spec[:modules].map { |n| modules[n].id }
        stale_tms = t.template_modules.where.not(node_module_id: desired_module_ids)
        if stale_tms.any?
          removed = stale_tms.count
          stale_tms.destroy_all
          log.call("      ↻ Removed #{removed} stale TemplateModule(s) from #{t.name}")
        end

        log.call("    ✓ NodeTemplate: #{t.name} → [#{spec[:modules].join(', ')}]")
      end

      modules
    end

    # ---- Per-account bootstrap helpers --------------------------------

    private

    def seed_provider!
      @provider = ::System::Provider.find_or_create_by!(account_id: @account.id, name: DEFAULT_PROVIDER_NAME) do |p|
        p.provider_type = DEFAULT_PROVIDER_TYPE
        p.enabled = true
        p.config  = {}
        p.capabilities = { "supports" => %w[provision start stop reboot terminate] }
      end
    end

    def seed_regions!
      DEFAULT_REGIONS.each do |attrs|
        ::System::ProviderRegion.find_or_create_by!(
          provider_id: @provider.id,
          region_code: attrs[:region_code]
        ) do |r|
          r.account     = @account
          r.name        = attrs[:name]
          r.enabled     = true
          r.capabilities = {}
        end
      end
    end

    def seed_instance_types!
      DEFAULT_INSTANCE_TYPES.each do |attrs|
        ::System::ProviderInstanceType.find_or_create_by!(
          provider_id: @provider.id,
          instance_type_code: attrs[:instance_type_code]
        ) do |t|
          t.account      = @account
          t.name         = attrs[:name]
          t.vcpus        = attrs[:vcpus]
          t.memory_mb    = attrs[:memory_mb]
          t.hourly_price = attrs[:hourly_price]
          t.enabled      = true
        end
      end
    end

    def seed_templates!
      self.class.seed_templates_for(@account, verbose: false)
    end
  end
end
