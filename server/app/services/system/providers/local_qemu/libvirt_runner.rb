# frozen_string_literal: true

require "open3"

module System
  module Providers
    module LocalQemu
      # Production virsh-shell-out runner. Each method runs a separate
      # `virsh` process so failures are isolated. Preferred over the
      # libvirt-ruby gem because virsh is vendored in every libvirt
      # install — no FFI dependency.
      class LibvirtRunner
        URI = ENV.fetch("POWERNODE_LIBVIRT_URI", "qemu:///system")

        def uri_check!
          out = run_virsh("uri")
          out[:ok] ? out.merge(uri: out[:stdout].strip) : out
        end

        def define_domain!(xml:, name:)
          # Pipe XML on stdin instead of a temp file — avoids file-permission
          # surprises when libvirt runs as a different user.
          run_virsh("define", "/dev/stdin", stdin: xml)
        end

        def start_domain!(name:)
          run_virsh("start", name)
        end

        def shutdown_domain!(name:)
          run_virsh("shutdown", name)
        end

        def destroy_domain!(name:)
          run_virsh("destroy", name)
        end

        def reboot_domain!(name:)
          run_virsh("reboot", name)
        end

        def undefine_domain!(name:)
          run_virsh("undefine", name, "--remove-all-storage", "--nvram")
        end

        # Returns { ok:, state: "running"|"shut off"|..., private_ip: nil }
        def dominfo!(name:)
          info = run_virsh("dominfo", name)
          return info unless info[:ok]
          state = info[:stdout].lines.find { |l| l.start_with?("State:") }&.sub(/^State:\s*/, "")&.strip
          info.merge(state: state, private_ip: lookup_private_ip(name))
        end

        # Multi-source IP discovery. virsh `domifaddr` only returns leases when
        # libvirt itself is the DHCP server (libvirt-managed networks) OR when
        # qemu-guest-agent is installed in the VM. For routed-mode networks
        # (POWERNODE_LIBVIRT_NETWORK_MODE=routed with an external dnsmasq on
        # pwnvbr0), neither holds — the lease lives in the dnsmasq leases file
        # the operator configured. Try each source in order; first hit wins.
        def lookup_private_ip(name)
          ip_from_domifaddr(name) || ip_from_dnsmasq_leases(domain_mac(name))
        end

        def list_domains!
          info = run_virsh("list", "--all")
          return info unless info[:ok]
          domains = info[:stdout].lines.drop(2).filter_map do |line|
            cols = line.split
            next if cols.size < 3
            { id: cols[0], name: cols[1], state: cols[2..].join(" ") }
          end
          { ok: true, domains: domains }
        end

        private

        def ip_from_domifaddr(name)
          out = run_virsh("domifaddr", name, fail_silently: true)
          return nil unless out[:ok]
          out[:stdout].lines.grep(/ipv4/).first&.split&.last&.split("/")&.first
        end

        # Fallback: parse dnsmasq lease files by MAC. Standard dnsmasq lease
        # format is space-separated: `<expiry-epoch> <mac> <ip> <hostname> <client_id>`.
        # Configurable via POWERNODE_DNSMASQ_LEASES (colon-separated paths) for
        # operators who run dnsmasq with a non-standard leasefile path; the
        # default list covers the libvirt default network plus the platform's
        # routed-mode bridge (pwnvbr0).
        DEFAULT_DNSMASQ_LEASE_PATHS = %w[
          /var/lib/libvirt/dnsmasq/default.leases
          /var/lib/libvirt/dnsmasq/virbr0.status
          /tmp/pwnvbr0-dnsmasq.leases
          /var/lib/misc/dnsmasq.leases
        ].freeze

        # Walks dnsmasq lease files for the given MAC, returns the IP from
        # the most-recently-leased entry. Multiple matches are common when
        # a VM cycles through addresses across boots (e.g. .26 then .88) —
        # picking by max expiry-time is the only correct disambiguation.
        # Skips JSON-format files (libvirt's *.status uses JSON, not the
        # space-separated lease format).
        def ip_from_dnsmasq_leases(mac)
          return nil if mac.blank?
          mac = mac.downcase
          best = nil # [expiry_epoch, ip]
          lease_paths.each do |path|
            next unless File.exist?(path) && File.readable?(path)
            first_byte = File.open(path, &:readbyte) rescue nil
            next if [ "[".ord, "{".ord ].include?(first_byte) # JSON, not classic-format leases
            File.foreach(path) do |line|
              cols = line.split
              next unless cols.size >= 3
              next unless cols[1].to_s.downcase == mac
              next unless valid_routable_ipv4?(cols[2])
              expiry = cols[0].to_i
              best = [ expiry, cols[2] ] if best.nil? || expiry > best[0]
            end
          rescue StandardError
            next
          end
          best&.last
        end

        # Reject 0.0.0.0, link-local 169.254.0.0/16, multicast, and loopback —
        # leases for those slip through dnsmasq sometimes when DHCP collides
        # with a duplicate-mac VM and we don't want to surface them as the
        # "primary" instance IP.
        def valid_routable_ipv4?(ip)
          return false if ip.blank?
          octets = ip.split(".").map(&:to_i)
          return false unless octets.size == 4 && octets.all? { |o| o.between?(0, 255) }
          return false if octets[0].zero? || octets[0] == 127 || octets[0] >= 224
          return false if octets[0] == 169 && octets[1] == 254
          true
        end

        def lease_paths
          if (override = ENV["POWERNODE_DNSMASQ_LEASES"])
            override.split(":").reject(&:empty?)
          else
            DEFAULT_DNSMASQ_LEASE_PATHS
          end
        end

        # virsh domiflist output:
        #   Interface   Type     Source     Model    MAC
        #  -------------------------------------------------
        #   vnet0       bridge   pwnvbr0    virtio   52:54:00:6c:ad:eb
        # Returns the FIRST interface's MAC. VMs with multiple NICs are rare
        # in this provider; if they show up we'd want a richer return shape.
        def domain_mac(name)
          out = run_virsh("domiflist", name, fail_silently: true)
          return nil unless out[:ok]
          out[:stdout].lines.drop(2).each do |line|
            cols = line.split
            next if cols.size < 5
            mac = cols.last
            return mac if mac.match?(/\A([0-9a-f]{2}:){5}[0-9a-f]{2}\z/i)
          end
          nil
        end

        def run_virsh(*args, stdin: nil, fail_silently: false)
          cmd = [ "virsh", "-c", URI, *args ]
          stdout, stderr, status = if stdin
                                     Open3.capture3(*cmd, stdin_data: stdin)
          else
                                     Open3.capture3(*cmd)
          end
          if status.success?
            { ok: true, stdout: stdout, stderr: stderr }
          elsif fail_silently
            { ok: false, error: stderr.strip, stdout: stdout, fail_silent: true }
          else
            { ok: false, error: stderr.strip.presence || "virsh exit #{status.exitstatus}" }
          end
        rescue Errno::ENOENT
          { ok: false, error: "virsh not found in PATH" }
        end
      end
    end
  end
end
