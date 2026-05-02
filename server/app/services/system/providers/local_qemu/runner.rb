# frozen_string_literal: true

module System
  module Providers
    module LocalQemu
      # Runner interface for the libvirt domain operations LocalQemuProvider
      # delegates to. Three implementations:
      #
      #   - LibvirtRunner    — shells out to virsh against the configured URI
      #   - RecorderRunner   — captures invocations for tests; returns scripted ok
      #   - DisabledRunner   — returns 503-style errors; for hosts without libvirt
      #
      # Each method returns { ok: Boolean, ...details, error: String }. The
      # provider normalizes these into BaseProvider response shapes.
      module Runner
        REQUIRED = %i[
          uri_check! define_domain! start_domain! shutdown_domain!
          destroy_domain! reboot_domain! undefine_domain! dominfo! list_domains!
        ].freeze
      end
    end
  end
end
