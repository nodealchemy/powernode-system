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
          ip_info = run_virsh("domifaddr", name, fail_silently: true)
          ip = nil
          if ip_info[:ok]
            ip = ip_info[:stdout].lines.grep(/ipv4/).first&.split&.last&.split("/")&.first
          end
          info.merge(state: state, private_ip: ip)
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
