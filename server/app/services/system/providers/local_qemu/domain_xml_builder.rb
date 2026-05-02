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
        def self.build(instance:, domain_name:, fw_cfg_entries:, arch:, memory_mb:, vcpus:, image_base:)
          new.build(instance: instance, domain_name: domain_name,
                    fw_cfg_entries: fw_cfg_entries, arch: arch,
                    memory_mb: memory_mb, vcpus: vcpus, image_base: image_base)
        end

        def build(instance:, domain_name:, fw_cfg_entries:, arch:, memory_mb:, vcpus:, image_base:)
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

          <<~XML
            <domain type='kvm' xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'>
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
              <cpu mode='host-passthrough' check='none'/>
              <clock offset='utc'/>
              <on_poweroff>destroy</on_poweroff>
              <on_reboot>restart</on_reboot>
              <on_crash>destroy</on_crash>
              <devices>
                <emulator>#{emulator}</emulator>
                #{disk_xml(domain_name)}
                #{network_xml}
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
        # with `opt/` per QEMU's reservation rule.
        def build_fw_cfg_qemu_args(entries)
          entries.map do |key, value|
            file_path = "/var/run/powernode-fwcfg/#{key.gsub('/', '_')}"
            # Stage-on-disk approach so libvirt apparmor doesn't complain
            # about long inline values. The CloudSeed.build path writes
            # these files before this XML is loaded.
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
          <<~XML.strip
              <disk type='file' device='disk'>
                  <driver name='qemu' type='qcow2'/>
                  <source file='/var/lib/libvirt/images/#{escape(domain_name)}.qcow2'/>
                  <target dev='vda' bus='virtio'/>
                </disk>
          XML
        end

        def network_xml
          <<~XML.strip
              <interface type='network'>
                  <source network='default'/>
                  <model type='virtio'/>
                </interface>
          XML
        end

        def console_xml
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
