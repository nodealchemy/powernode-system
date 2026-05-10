# frozen_string_literal: true

module System
  module Providers
    module LocalQemu
      # Builds libvirt domain XML for a NodeInstance with direct kernel/initrd
      # boot from the M3 image artifacts and a virtio-fw-cfg seed for the
      # bootstrap token + CA + instance UUID.
      #
      # Direct kernel boot is preferred over disk boot for the M4 thin slice
      # because:
      #   1. It bypasses bootloader complexity (no GRUB needed in the image)
      #   2. The kernel cmdline is fully under our control
      #   3. Iteration during early dev is faster (no qcow2 rebake per change)
      #
      # Reference: Golden Eclipse plan M4 — providers/local_qemu/domain_xml_builder.
      class DomainXmlBuilder
        # Build the domain XML.
        #
        # @param instance [System::NodeInstance]
        # @param domain_name [String] libvirt domain name (must be unique)
        # @param fw_cfg_entries [Hash<String, String>] virtio-fw-cfg key→value pairs
        #   Keys must be in opt/<domain>/<name> form per qemu's fw-cfg convention.
        # @param arch ["amd64"|"arm64"]
        # @param memory_mb [Integer]
        # @param vcpus [Integer]
        # @param image_base [String] absolute filesystem path or HTTP URL
        #   to the M3 build dir; e.g. "/var/lib/powernode/images" or
        #   "https://platform/.well-known/powernode/images"
        # @return [String] libvirt domain XML
        def self.build(instance:, domain_name:, fw_cfg_entries:, arch:, memory_mb:, vcpus:, image_base:, provider: nil)
          new(provider: provider).build(instance: instance, domain_name: domain_name,
                    fw_cfg_entries: fw_cfg_entries, arch: arch,
                    memory_mb: memory_mb, vcpus: vcpus, image_base: image_base)
        end

        def initialize(provider: nil)
          @provider = provider
        end

        def build(instance:, domain_name:, fw_cfg_entries:, arch:, memory_mb:, vcpus:, image_base:)
          @instance = instance
          # Persist the deterministic MAC on first generate so the rest of the
          # platform (audit, lease lookups) can reference it without re-deriving.
          if instance.respond_to?(:mac_address) && instance.mac_address.blank?
            mac = stable_mac
            instance.update_column(:mac_address, mac) if mac && instance.persisted?
          end
          arch_str = arch.to_s == "arm64" ? "aarch64" : "x86_64"
          machine = arch_str == "aarch64" ? "virt" : "q35"
          emulator = arch_str == "aarch64" ? "/usr/bin/qemu-system-aarch64" : "/usr/bin/qemu-system-x86_64"

          # Direct kernel boot: load kernel + initrd off the host filesystem.
          # If image_base is an HTTP URL the operator has pre-fetched these
          # to a local cache; this builder consumes paths only.
          kernel_path = "#{image_base}/#{arch}/kernel-initrd/kernel"
          initrd_path = "#{image_base}/#{arch}/kernel-initrd/initramfs.cpio.zst"

          fw_cfg_xml = build_fw_cfg_qemu_args(fw_cfg_entries)
          cmdline = build_kernel_cmdline(fw_cfg_entries)

          # libvirt domain type — kvm when /dev/kvm exists, qemu otherwise
          # (TCG software emulation; slower but works in nested-virt-disabled
          # environments and CI).
          domain_type = File.exist?("/dev/kvm") ? "kvm" : "qemu"
          cpu_mode    = domain_type == "kvm" ? "host-passthrough" : "host-model"

          <<~XML
            <domain type='#{domain_type}' xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'>
              <name>#{escape(domain_name)}</name>
              <uuid>#{escape(instance.id)}</uuid>
              <memory unit='MiB'>#{memory_mb}</memory>
              <currentMemory unit='MiB'>#{memory_mb}</currentMemory>
              <vcpu placement='static'>#{vcpus}</vcpu>
              <os>
                <type arch='#{arch_str}' machine='#{machine}'>hvm</type>
                <kernel>#{escape(kernel_path)}</kernel>
                <initrd>#{escape(initrd_path)}</initrd>
                <cmdline>#{escape(cmdline)}</cmdline>
              </os>
              <features>
                <acpi/>
                <apic/>
              </features>
              <cpu mode='#{cpu_mode}' check='none'/>
              <clock offset='utc'/>
              <on_poweroff>destroy</on_poweroff>
              <on_reboot>restart</on_reboot>
              <on_crash>destroy</on_crash>
              <devices>
                <emulator>#{emulator}</emulator>
                #{disk_xml(domain_name)}
                #{network_xml}
                #{modules_share_xml}
                #{console_xml}
                <rng model='virtio'>
                  <backend model='random'>/dev/urandom</backend>
                </rng>
              </devices>
              <qemu:commandline>
            #{fw_cfg_xml}
              </qemu:commandline>
            </domain>
          XML
        end

        private

        # virtio-fw-cfg entries are passed via QEMU's `-fw_cfg` arg. Each
        # entry becomes one <qemu:arg value='...'/> pair. Names must start
        # with `opt/` per QEMU's reservation rule. The path matches
        # CloudSeed::FWCFG_DIR, which CloudSeed.build wrote before this
        # XML is loaded — keeping the two in sync via shared constant.
        def build_fw_cfg_qemu_args(entries)
          fwcfg_dir = ::System::Providers::LocalQemu::CloudSeed::FWCFG_DIR
          entries.map do |key, _value|
            file_path = File.join(fwcfg_dir, key.gsub("/", "_"))
            <<~XMLPAIR
                <qemu:arg value='-fw_cfg'/>
                <qemu:arg value='name=#{key},file=#{file_path}'/>
            XMLPAIR
          end.join.rstrip
        end

        # Kernel cmdline already carries powernode.boot=1 + lockdown +
        # IMA from the dracut config. We add console=ttyS0 for libvirt
        # serial console capture and the fw-cfg discovery hint.
        def build_kernel_cmdline(_entries)
          parts = [
            "console=tty1",
            "console=ttyS0,115200",
            "lockdown=integrity",
            "ima_appraise=enforce",
            "ima_template=ima-ng",
            "powernode.boot=1",
            "powernode.identity_source=fwcfg"
          ]
          parts.join(" ")
        end

        def disk_xml(domain_name)
          # Skip the disk entirely when no qcow2 was pre-staged. The M4 thin
          # slice boots directly into kernel+initramfs+powernode-agent; persistent
          # /var on disk lands in M3 (raw disk image variant).
          disk_dir = ENV.fetch("POWERNODE_DISK_DIR", "/var/lib/libvirt/images")
          disk_path = File.join(disk_dir, "#{domain_name}.qcow2")
          return "" unless File.exist?(disk_path)

          <<~XML.strip
              <disk type='file' device='disk'>
                  <driver name='qemu' type='qcow2'/>
                  <source file='#{escape(disk_path)}'/>
                  <target dev='vda' bus='virtio'/>
                </disk>
          XML
        end

        # Four networking modes selectable via POWERNODE_NETWORK_MODE:
        #
        #   user    — QEMU slirp (10.0.2.15 + NAT-to-host). No host setup needed.
        #             Default under qemu:///session.
        #   network — libvirt-managed network (default: 'default' = virbr0
        #             with built-in dnsmasq DHCP on 192.168.122.0/24, NAT
        #             upstream). Default under qemu:///system.
        #   bridge  — true Linux bridge (e.g. br0 enslaving the host's
        #             physical NIC). VM gets a real LAN DHCP lease from
        #             the upstream router and joins the LAN as a peer.
        #             Requires:
        #               • a host bridge created out-of-band (nmcli or netplan)
        #               • /etc/qemu/bridge.conf containing 'allow <bridge>'
        #                 (so qemu-bridge-helper, which is setuid root,
        #                 permits session-mode VMs to attach a tap)
        #               • on a nested-virt host: L0 must allow MAC spoofing
        #                 / promiscuous mode on the L1 vNIC, otherwise the
        #                 VM's frames are dropped because their MAC differs
        #                 from the L1's
        #             Override the bridge name with POWERNODE_BRIDGE_NAME (default: br0).
        #   routed  — Platform-managed host-internal bridge for routed-mode VMs.
        #             Phase O1: bridge name and lifecycle owned by
        #             Sdwan::HostBridge; the on-node agent's BridgeApplier
        #             reconciles host kernel state to match. The libvirt
        #             host is identified by provider.config["host_node_instance_id"];
        #             Sdwan::HostBridgeResolver looks up the active bridge
        #             for that host. No env-based override path — allocate
        #             a Sdwan::HostBridge first, then provision routed VMs.
        #
        # Resolution order for `mode` (most specific → most general):
        #   1. Provider#config["network_mode"]   — per-provider UI setting
        #   2. ENV["POWERNODE_NETWORK_MODE"]      — global override
        #   3. default_network_mode               — heuristic from URI
        # Same chain for the `bridge` mode's bridge_name (provider config →
        # env → "br0"). The `routed` mode skips this chain entirely — its
        # bridge name comes from Sdwan::HostBridge.
        def network_xml
          mode = provider_config_value("network_mode") ||
                 ENV["POWERNODE_NETWORK_MODE"] ||
                 default_network_mode
          mac_xml = stable_mac ? "<mac address='#{stable_mac}'/>" : ""
          case mode
          when "bridge"
            bridge = provider_config_value("bridge_name") ||
                     ENV["POWERNODE_BRIDGE_NAME"] ||
                     "br0"
            <<~XML.strip
                <interface type='bridge'>
                    <source bridge='#{escape(bridge)}'/>
                    #{mac_xml}
                    <model type='virtio'/>
                  </interface>
            XML
          when "routed"
            # Routed mode: VM attaches to a platform-managed host-internal
            # bridge with IP forwarding enabled but NO MASQUERADE. The host
            # routes traffic in/out via the bridge IP. The VM gets a stable
            # host-routable IP from the bridge's subnet. This is the underlay
            # for the platform's SDWAN overlay — WireGuard rides over this
            # routed subnet to reach SDWAN gateways.
            #
            # Phase O1: bridge name + lifecycle are owned by Sdwan::HostBridge,
            # reconciled by the on-node agent's BridgeApplier. The resolver
            # is the SINGLE SOURCE OF TRUTH — passing a literal bridge name
            # via env or provider config is no longer supported in routed
            # mode. Operators (and the AI fleet) allocate a HostBridge per
            # host once via Sdwan::HostBridgeAllocator before provisioning
            # routed-mode VMs on that host.
            host = routed_mode_host
            bridge = ::Sdwan::HostBridgeResolver.bridge_name_for(host)
            <<~XML.strip
                <interface type='bridge'>
                    <source bridge='#{escape(bridge)}'/>
                    #{mac_xml}
                    <model type='virtio'/>
                  </interface>
            XML
          when "user"
            <<~XML.strip
                <interface type='user'>
                    #{mac_xml}
                    <model type='virtio'/>
                  </interface>
            XML
          else # "network" or any unknown → libvirt-managed network
            net = ENV.fetch("POWERNODE_LIBVIRT_NETWORK", "default")
            <<~XML.strip
                <interface type='network'>
                    <source network='#{escape(net)}'/>
                    #{mac_xml}
                    <model type='virtio'/>
                  </interface>
            XML
          end
        end

        # Stable MAC derived from instance.id — same VM always gets the same
        # MAC across destroy/create cycles, so DHCP leases stick. Uses the
        # KVM-reserved 52:54:00 OUI to avoid clashing with real hardware.
        # First 3 bytes of SHA256(instance.id) provide the variable octets;
        # 24 bits of namespace = ~16M unique MACs per OUI, collision-free
        # against UUIDv7 instance IDs at platform scale.
        def stable_mac
          return nil unless @instance&.id
          digest = ::Digest::SHA256.hexdigest(@instance.id.to_s)
          "52:54:00:#{digest[0, 2]}:#{digest[2, 2]}:#{digest[4, 2]}"
        end

        # virtio-9p passthrough share for the dev-mode local-fs module loader.
        # Exposes the host's /var/lib/powernode/modules tree (or
        # POWERNODE_MODULES_DIR override) into the guest at the 9p tag
        # `powernode_modules`. The on-node agent's `prepare-root` subcommand
        # mounts this share at /run/powernode/modules and stacks per-module
        # rootfs/ subdirs as overlayfs lower layers.
        #
        # Skipped when the host directory doesn't exist yet (no modules built),
        # so existing smoke runs that don't need the share keep working.
        def modules_share_xml
          host_dir = ENV.fetch("POWERNODE_MODULES_DIR", "/var/lib/powernode/modules")
          return "" unless File.directory?(host_dir)

          # virtio-9p is built into qemu (no extra daemon vs. virtiofs which
          # needs virtiofsd running per-share). Default driver = 9p; the
          # guest mounts with `mount -t 9p -o trans=virtio,version=9p2000.L`.
          <<~XML.strip
              <filesystem type='mount' accessmode='passthrough'>
                  <source dir='#{escape(host_dir)}'/>
                  <target dir='powernode_modules'/>
                  <readonly/>
                </filesystem>
          XML
        rescue StandardError
          ""
        end

        def default_network_mode
          libvirt_uri = ENV.fetch("POWERNODE_LIBVIRT_URI", "qemu:///system")
          libvirt_uri.include?("session") ? "user" : "network"
        end

        # Read a key out of the provider's config JSONB (System::Provider#config).
        # Returns nil when no provider was passed, the key is missing, or the
        # value is blank — letting the caller fall through to env-var defaults.
        def provider_config_value(key)
          return nil unless @provider
          cfg = @provider.respond_to?(:config) ? @provider.config : nil
          val = cfg.is_a?(Hash) ? cfg[key.to_s] : nil
          val.is_a?(String) && val.strip.empty? ? nil : val
        end

        # Resolve the host (NodeInstance) that this routed-mode VM is being
        # placed on. Used by Sdwan::HostBridgeResolver to find the
        # platform-managed bridge name.
        #
        # Resolution: provider.config["host_node_instance_id"] points at
        # the NodeInstance that represents the libvirt host. This is set
        # once per provider when the operator (or AI fleet) onboards the
        # host. Without it, no clean way exists to know which host's
        # HostBridge to consume — so we raise a clear error rather than
        # silently fall back to a stale literal.
        def routed_mode_host
          host_id = provider_config_value("host_node_instance_id")
          unless host_id
            raise ::Sdwan::HostBridgeResolver::NoBridgeForHost,
                  "routed mode requires a host context — set " \
                  "provider.config['host_node_instance_id'] to the NodeInstance " \
                  "id of the libvirt host, then allocate a Sdwan::HostBridge " \
                  "for that host via Sdwan::HostBridgeAllocator.allocate!(host:)"
          end

          host = ::System::NodeInstance.find_by(id: host_id)
          return host if host

          raise ::Sdwan::HostBridgeResolver::NoBridgeForHost,
                "provider config host_node_instance_id=#{host_id} does not " \
                "match any System::NodeInstance — point this provider at a " \
                "valid host instance before provisioning routed-mode VMs"
        end

        def console_xml
          # When POWERNODE_SERIAL_LOG_DIR is set, redirect serial console
          # to a per-domain log file in addition to the pty. Useful for CI
          # smoke tests where there's no controlling TTY for `virsh console`.
          serial_dir = ENV["POWERNODE_SERIAL_LOG_DIR"]
          if serial_dir && !serial_dir.empty?
            require "fileutils"
            FileUtils.mkdir_p(serial_dir, mode: 0o755)
            log_path = File.join(serial_dir, "domain-serial.log")
            return <<~XML.strip
                <serial type='file'>
                    <source path='#{escape(log_path)}' append='off'/>
                    <target type='isa-serial' port='0'/>
                  </serial>
                  <console type='file'>
                    <source path='#{escape(log_path)}' append='off'/>
                    <target type='serial' port='0'/>
                  </console>
            XML
          end

          <<~XML.strip
              <serial type='pty'>
                  <target type='isa-serial' port='0'/>
                </serial>
                <console type='pty'>
                  <target type='serial' port='0'/>
                </console>
          XML
        end

        def escape(str)
          str.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
            .gsub('"', "&quot;").gsub("'", "&apos;")
        end
      end
    end
  end
end
